#!/usr/bin/env bash
# pipewire-browser-camera-fix.sh — get the camera working again in Chrome,
# Chromium and Firefox when they use it through PipeWire.
# https://github.com/david-bartlett/pipewire-browser-camera-fix
#
# Checks three things and, with your OK, fixes them:
#
#   1. Chrome / Chromium PipeWire camera flag
#      (chrome://flags/#enable-webrtc-pipewire-camera) in every Chrome-family
#      profile: native, snap and Flatpak Chrome, Chromium, Brave, Vivaldi, Opera.
#      Edited directly in each profile's "Local State", never while that browser
#      runs. A flag you set to Disabled yourself is only changed if you say so.
#   2. Firefox PipeWire camera pref (media.webrtc.camera.allow-pipewire): on,
#      except in snap Firefox, which crashes on the PipeWire camera, so there
#      it's turned off.
#   3. xdg-desktop-portal camera permission for the browsers GNOME cannot show
#      the "allow camera?" dialog for. See the README for why: on GNOME, Chrome
#      and snap browsers wait forever at "Waiting for your permission", and the
#      user journal shows "Only the focused app is allowed to show a system
#      access dialog".
#
# Usage: pipewire-browser-camera-fix.sh [--check | --yes | --undo | --status]
#        pipewire-browser-camera-fix.sh --enable TARGET [--disable TARGET]...
#        pipewire-browser-camera-fix.sh --allow ID...
#
#   (none)    check, then ask before each change
#   --check   check only, change nothing
#   --yes     make every safe change without asking (never removes a stored
#             "no" from the portal — that one always asks)
#   --undo    put back everything this script changed; anything it can't (a
#             browser running, the portal unreachable) stays recorded for the
#             next --undo, and it exits 1
#   --status  the same checks as --check, as tab-separated lines for other
#             programs (a settings window, say); changes nothing
#   --enable TARGET, --disable TARGET
#             turn one browser's setting on, or back to the browser's own
#             default (snap Firefox: off). TARGET is a Chrome-family profile
#             folder, a Firefox prefs.js or an Edge command (Edge's switch goes
#             in its flags file or menu entry), as --status lists them. Can be
#             given more than once; recorded for --undo like any change.
#             Exits 1 if any target couldn't be changed (a browser running,
#             say), with the reason
#   --allow ID
#             store a portal "yes" for one browser's app ID, as --status lists
#             them: for a stored "no", or "not set" where the desktop can't show
#             the dialog (GNOME). "--allow ''" is the empty ID (apps the portal
#             can't name), only to clear a stored "no" there. Recorded for --undo
#
# Run it as yourself, not with sudo: it edits your browser profiles and talks
# to the portal on your session bus.

set -uo pipefail

STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/pipewire-browser-camera-fix/changes"
# Before the rename, changes were recorded here; --undo still reads it.
LEGACY_STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/browser-camera-fix/changes"
FF_PREF="media.webrtc.camera.allow-pipewire"
FF_BACKUP_SUFFIX=".pipewire-browser-camera-fix.bak"
# Chrome's name for the flag; "@1" is Enabled, "@2" Disabled in Local State.
CHROME_FLAG="enable-webrtc-pipewire-camera"
CHROME_BACKUP_SUFFIX=".pipewire-browser-camera-fix.bak"

PORTAL_STORE="org.freedesktop.impl.portal.PermissionStore"
PORTAL_STORE_PATH="/org/freedesktop/impl/portal/PermissionStore"

MODE="fix"
SET_TARGETS=()     # "on TARGET" / "off TARGET", for --enable / --disable
set_mode() {
    if [[ "$MODE" != fix && "$MODE" != "$1" ]]; then
        echo "Use one of --check, --yes, --undo, --status, or --enable/--disable/--allow (try --help)" >&2
        exit 2
    fi
    MODE="$1"
}
while (( $# )); do
    case "$1" in
        --check)  set_mode check ;;
        --yes)    set_mode yes ;;
        --undo)   set_mode undo ;;
        --status) set_mode status ;;
        --enable | --disable)
            if [[ -z "${2:-}" ]]; then
                echo "$1 needs a target: a profile folder or prefs.js from --status" >&2
                exit 2
            fi
            set_mode set
            if [[ "$1" == --enable ]]; then SET_TARGETS+=("on $2"); else SET_TARGETS+=("off $2"); fi
            shift ;;
        --allow)
            # The ID may be empty (apps the portal can't name), so only its presence counts.
            if (( $# < 2 )); then
                echo "--allow needs an app ID from --status (or '' for apps without one)" >&2
                exit 2
            fi
            set_mode set
            SET_TARGETS+=("allow $2")
            shift ;;
        -h|--help)
            sed -n '/^# Usage:/,/^# Run it/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "Unknown option: $1 (try --help)" >&2
            exit 2 ;;
    esac
    shift
done

if [[ $EUID -eq 0 ]]; then
    echo "Run this as yourself, not with sudo: it edits your browser profiles and" >&2
    echo "uses the portal on your session bus." >&2
    exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

section() { echo; echo "── $* ──"; }

# Is this typed answer a yes? Enter alone gives the default ($1: yes or no).
answer_yes() {
    case "$2" in
        [yY] | [yY][eE][sS]) return 0 ;;
        "") [[ "$1" == yes ]] ;;
        *) return 1 ;;
    esac
}

# Yes/no question for the fixes this script is run for, so Enter means yes.
# --yes answers yes; anything without a terminal answers no.
ask() {
    [[ "$MODE" == "yes" ]] && return 0
    [[ -t 0 ]] || return 1
    local answer
    read -rp "  $* [Y/n] " answer
    answer_yes yes "$answer"
}

# Always asks, even under --yes, and Enter means no. For changes that undo a
# decision the user may have made on purpose.
ask_always() {
    [[ -t 0 ]] || return 1
    local answer
    read -rp "  $* [y/N] " answer
    answer_yes no "$answer"
}

record() {
    mkdir -p "${STATE_FILE%/*}"
    grep -qxF "$*" "$STATE_FILE" 2>/dev/null || echo "$*" >> "$STATE_FILE"
}

# Is there a record already for this profile or portal app ID? $1 is chrome,
# firefox, portal or edge, $2 the profile folder, prefs.js, app ID or Edge's
# flags file or menu entry. The first
# record holds the state from before this script's first change, so a later
# run (after the user changed it back, say) adds no second one: --undo puts
# back the original, not an in-between state.
recorded() {
    local kind rest f
    [[ -r "$STATE_FILE" ]] || return 1
    while IFS=' ' read -r kind rest; do
        case "$1:$kind" in
            chrome:chrome)            [[ "${rest#* }" == "$2" ]] && return 0 ;;
            firefox:firefox)          [[ "${rest% *}" == "$2" ]] && return 0 ;;
            portal:portal | portal:portal-was-no)
                                      [[ "$rest" == "$2" ]] && return 0 ;;
            edge:edge-flags)          f=${rest#* }; [[ "${f#* }" == "$2" ]] && return 0 ;;
            edge:edge-desktop)        [[ "$rest" == "$2" ]] && return 0 ;;
        esac
    done < "$STATE_FILE"
    return 1
}

# ── Portal permission store ───────────────────────────────────────────────────

portal_store() {
    busctl --user --timeout=5 call "$PORTAL_STORE" "$PORTAL_STORE_PATH" "$PORTAL_STORE" "$@"
}

# Every stored camera decision, as busctl prints it:
#   a{sas}v 2 "com.google.Chrome" 1 "yes" "org.mozilla.firefox" 1 "no" ...
# Succeeds with no output when nothing is stored yet: the store answers
# "No entry for camera" until the first decision.
portal_camera_entries() {
    command -v busctl &>/dev/null || return 1
    local out
    if out=$(portal_store Lookup ss devices camera 2>&1); then
        printf '%s\n' "$out"
        return 0
    fi
    [[ "$out" == *"No entry"* ]] && return 0
    return 1
}

# Stored decision for one app ID: yes, no, ask — or nothing when unset.
portal_camera_state() {
    grep -oP "\"\Q$2\E\" [0-9]+ \"\K[^\"]*" <<< "$1" | head -1 || true
}

# IDs of running Chromium-family browsers, from the scope Chromium creates for
# itself: app-<ID>-<own pid>.scope. Catches forks (Brave, Edge, Vivaldi, Opera)
# whose ID can't be known in advance. $1 is the proc root.
running_chromium_scope_ids() {
    local proc="${1:-/proc}" cg pid line exe
    for cg in "$proc"/[0-9]*/cgroup; do
        [[ -r "$cg" ]] || continue
        pid=${cg%/cgroup}
        pid=${pid##*/}
        while IFS= read -r line; do
            [[ "$line" =~ /app-([^/-]+)-${pid}\.scope$ ]] || continue
            exe=$(readlink "$proc/$pid/exe" 2>/dev/null) || continue
            case "${exe##*/}" in
                chrome|chromium|chromium-browser|brave|msedge|vivaldi-bin|opera|thorium)
                    # Unit names escape anything unusual as \xNN.
                    printf '%b\n' "${BASH_REMATCH[1]}" ;;
            esac
        done 2>/dev/null < "$cg" || true
    done
    return 0
}

# App IDs the portal uses for the browsers on this machine — the ones whose
# dialog GNOME refuses. $1 is the proc root, $2 the snap mount root.
#
#   Native Chrome moves itself into a systemd scope named after a fixed ID, and
#   the portal takes the app ID from that unit: com.google.Chrome, with .beta,
#   .unstable or .canary for the other channels, and org.chromium.Chromium for
#   non-Google builds (Chromium: base/version_info/nix/version_extra_utils.cc,
#   GetAppName). Its window belongs to google-chrome.desktop.
#
#   A snap is snap.<name> to the portal (xdg-desktop-portal:
#   shared/xdp-app-info-snap.c) and <name>_<app>.desktop to GNOME.
#
#   Native and Flatpak Firefox are not listed: launched from the app menu, the
#   ID the portal sees matches the window, and the dialog works.
browser_portal_app_ids() {
    local proc="${1:-/proc}" snaps="${2:-/snap}" entry name
    {
        for entry in google-chrome-stable: google-chrome-beta:.beta \
                     google-chrome-unstable:.unstable google-chrome-canary:.canary; do
            if command -v "${entry%%:*}" &>/dev/null; then
                echo "com.google.Chrome${entry#*:}"
            fi
        done
        # Brave and Opera name their scope org.chromium.Chromium too, and
        # Vivaldi com.vivaldi.Vivaldi (seen on EndeavourOS, 23 Nov 2026), so
        # installed is enough: they needn't be running when this runs.
        if command -v chromium &>/dev/null || command -v chromium-browser &>/dev/null \
           || command -v brave &>/dev/null || command -v brave-browser &>/dev/null \
           || command -v opera &>/dev/null; then
            echo "org.chromium.Chromium"
        fi
        if command -v vivaldi &>/dev/null || command -v vivaldi-stable &>/dev/null; then
            echo "com.vivaldi.Vivaldi"
        fi
        for name in firefox chromium brave; do
            if [[ -d "$snaps/$name/current" ]]; then
                echo "snap.$name"
            fi
        done
        running_chromium_scope_ids "$proc"
    } | sort -u
    return 0
}

# ── Firefox ───────────────────────────────────────────────────────────────────

# Every Firefox prefs.js under the native, XDG, snap and Flatpak locations.
firefox_prefs_files() {
    local root prefs
    for root in "$HOME/.mozilla/firefox" \
                "${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox" \
                "$HOME/snap/firefox/common/.mozilla/firefox" \
                "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox" \
                "$HOME/.var/app/org.mozilla.firefox/config/mozilla/firefox"; do
        [[ -d "$root" ]] || continue
        for prefs in "$root"/*/prefs.js; do
            [[ -f "$prefs" ]] && printf '%s\n' "$prefs"
        done
    done
    return 0
}

# Firefox 147 and later keep profiles in ~/.config/mozilla (XDG), but only when
# ~/.mozilla doesn't exist: while it does (or MOZ_LEGACY_HOME is set), Firefox
# goes on using ~/.mozilla and never reads the XDG folder (Mozilla bug 259356).
# Flatpak Firefox does the same inside ~/.var/app/org.mozilla.firefox. Prints
# the folder Firefox uses instead when $1 is in a profile it doesn't use.
firefox_unused_profile() {
    local prefs="$1" flatpak="$HOME/.var/app/org.mozilla.firefox"
    case "$prefs" in
        "${XDG_CONFIG_HOME:-$HOME/.config}/mozilla/firefox/"*)
            if [[ -d "$HOME/.mozilla" || -n "${MOZ_LEGACY_HOME:-}" ]]; then
                echo "$HOME/.mozilla/firefox"; return 0
            fi ;;
        "$flatpak/config/mozilla/firefox/"*)
            if [[ -d "$flatpak/.mozilla" ]]; then
                echo "$flatpak/.mozilla/firefox"; return 0
            fi ;;
    esac
    return 1
}

# Is $1 the profile Firefox opens by default? installs.ini names the default
# profile per Firefox install; older setups only have Default=1 in profiles.ini.
firefox_default_profile() {
    local dir=${1%/prefs.js} root name
    root=${dir%/*}
    name=${dir##*/}
    if [[ -f "$root/installs.ini" ]]; then
        grep -qxF "Default=$name" "$root/installs.ini"
        return
    fi
    [[ -f "$root/profiles.ini" ]] || return 1
    awk -v want="$name" '
        /^\[/          { if (path == want && def) found = 1; path = ""; def = 0 }
        /^Path=/        { path = substr($0, 6) }
        /^Default=1$/   { def = 1 }
        END             { if (path == want && def) found = 1; exit !found }
    ' "$root/profiles.ini"
}

# The default a native Firefox package ships for the pref, as "value file":
# Fedora's firefox-redhat-default-prefs.js turns it on, for example. Nothing
# when no package sets it, and the pref is then off (Mozilla's default).
# FF_SYSTEM_ROOT is for the tests.
firefox_system_default() {
    local r="${FF_SYSTEM_ROOT:-}" dir file line found=""
    local -a files=()
    for dir in "$r"/usr/lib64/firefox "$r"/usr/lib/firefox "$r"/usr/lib64/firefox-esr \
               "$r"/usr/lib/firefox-esr "$r"/opt/firefox; do
        files+=("$dir"/defaults/pref/*.js "$dir"/browser/defaults/preferences/*.js)
    done
    files+=("$r"/etc/firefox/syspref.js "$r"/etc/firefox/pref/*.js "$r"/etc/firefox-esr/*.js)
    for file in "${files[@]}"; do
        [[ -f "$file" ]] || continue
        line=$(sed -n 's/^[[:space:]]*\(pref\|defaultPref\|lockPref\)("media\.webrtc\.camera\.allow-pipewire",[[:space:]]*\(true\|false\)).*/\2/p' \
            "$file" 2>/dev/null | tail -1)
        [[ -n "$line" ]] && found="$line ${file##*/}"
    done
    [[ -n "$found" ]] && echo "$found"
    return 0
}

# A user.js beside prefs.js is read at every start and wins over prefs.js:
# true, false, or nothing when it doesn't set the pref.
firefox_user_js_value() {
    firefox_pref_value "${1%/prefs.js}/user.js"
}

# true, false, or nothing when the pref is not in the file (Firefox's default).
firefox_pref_value() {
    sed -n 's/^[[:space:]]*user_pref("media\.webrtc\.camera\.allow-pipewire",[[:space:]]*\(true\|false\)).*/\1/p' \
        "$1" 2>/dev/null | tail -1
}

# Is Firefox installed at all (native, snap or Flatpak)? Tells "never opened"
# (no profile yet) from "not installed" when no profile is found. $1 is the
# snap mount root, for the tests.
# shellcheck disable=SC2120  # the tests pass the snap root
firefox_installed() {
    local snaps="${1:-/snap}"
    command -v firefox &>/dev/null || command -v firefox-esr &>/dev/null \
        || [[ -d "$snaps/firefox/current" ]] \
        || [[ -d "$HOME/.local/share/flatpak/app/org.mozilla.firefox" ]] \
        || [[ -d /var/lib/flatpak/app/org.mozilla.firefox ]]
}

# Firefox rewrites prefs.js when it quits, so an edit made while it runs is lost.
firefox_running() {
    pgrep -u "$(id -u)" -x 'firefox|firefox-bin|firefox-esr|GeckoMain' &>/dev/null
}

# Set the pref to $2 (true/false), or remove it when $2 is "unset".
# prefs.js is the profile's settings, so it's only replaced by a copy known to
# be whole: every step is checked, and the copy is flushed to disk first. On a
# full disk, grep used to write part of the file, its error was ignored, and
# the part went over the original. Any failure leaves prefs.js as it was and
# returns 1. The backup is made the same way, so it can't be a partial copy.
firefox_set_pref() {
    local prefs="$1" value="$2" tmp bak="$1$FF_BACKUP_SUFFIX" rc=0
    if [[ ! -e "$bak" ]]; then
        tmp=$(mktemp "${bak}.XXXXXX") || return 1
        if ! { cp -p "$prefs" "$tmp" && sync -- "$tmp" && mv -f "$tmp" "$bak"; }; then
            rm -f "$tmp"; return 1
        fi
    fi
    tmp=$(mktemp "${prefs}.XXXXXX") || return 1
    # grep -v: 0 = lines kept, 1 = no lines left (an empty prefs.js), >1 = error.
    grep -v "^[[:space:]]*user_pref(\"${FF_PREF//./\\.}\"" "$prefs" > "$tmp" || rc=$?
    if (( rc > 1 )); then rm -f "$tmp"; return 1; fi
    if [[ "$value" != "unset" ]]; then
        printf 'user_pref("%s", %s);\n' "$FF_PREF" "$value" >> "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    chmod --reference="$prefs" "$tmp" 2>/dev/null || true
    sync -- "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$prefs" || { rm -f "$tmp"; return 1; }
}

profile_label() {
    local prefs="$1" dir kind=""
    dir=${prefs%/prefs.js}
    case "$prefs" in
        "$HOME"/snap/*)     kind=" (snap)" ;;
        "$HOME"/.var/app/*) kind=" (flatpak)" ;;
    esac
    printf 'Firefox%s [%s]' "$kind" "${dir##*/}"
}

# ── Chrome / Chromium flag ────────────────────────────────────────────────────

# Every Chrome-family profile folder (the one holding "Local State"), as
# "label<TAB>folder": native (~/.config), snap and Flatpak.
chrome_profiles() {
    local root name dir kind label
    local -a names=(google-chrome google-chrome-beta google-chrome-unstable chromium
                    BraveSoftware/Brave-Browser vivaldi opera opera-beta opera-developer)
    local -A seen=()
    for root in "${XDG_CONFIG_HOME:-$HOME/.config}" "$HOME"/snap/*/current/.config "$HOME"/.var/app/*/config; do
        [[ -d "$root" ]] || continue
        case "$root" in
            "$HOME"/snap/*)     kind=" (snap)" ;;
            "$HOME"/.var/app/*) kind=" (flatpak)" ;;
            *)                  kind="" ;;
        esac
        for name in "${names[@]}"; do
            dir="$root/$name"
            [[ -f "$dir/Local State" ]] || continue
            # A snap's "current" links to a revision: report each profile once.
            dir=$(cd "$dir" 2>/dev/null && pwd -P) || continue
            [[ -n "${seen[$dir]:-}" ]] && continue
            seen[$dir]=1
            case "$name" in
                google-chrome)               label="Google Chrome" ;;
                google-chrome-beta)          label="Google Chrome Beta" ;;
                google-chrome-unstable)      label="Google Chrome Dev" ;;
                chromium)                    label="Chromium" ;;
                BraveSoftware/Brave-Browser) label="Brave" ;;
                vivaldi)                     label="Vivaldi" ;;
                opera*)                      label="Opera${name#opera}" ;;
            esac
            printf '%s%s\t%s\n' "$label" "$kind" "$dir"
        done
    done
    return 0
}

# Is the browser using this profile running? Chrome rewrites Local State when it
# quits, so an edit made while it runs is lost. SingletonLock links to
# "host-pid"; a Flatpak browser's pid is from inside its sandbox, so ask flatpak.
chrome_running() {
    local dir="$1" target pid app running
    if [[ "$dir" == "$HOME"/.var/app/* ]]; then
        app=${dir#"$HOME"/.var/app/}
        app=${app%%/*}
        if command -v flatpak &>/dev/null; then
            running=$(flatpak ps --columns=application 2>/dev/null) || running=""
            grep -qxF "$app" <<< "$running"
            return
        fi
        [[ -L "$dir/SingletonLock" ]]
        return
    fi
    target=$(readlink "$dir/SingletonLock" 2>/dev/null) || return 1
    pid=${target##*-}
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

# Read or change the flag in one profile's Local State.
#   chrome_flag DIR status       -> ENABLED, DISABLED or "not set"
#   chrome_flag DIR set 1|2      -> Enabled / Disabled
#   chrome_flag DIR remove       -> back to Default
# Only browser.enabled_labs_experiments is touched; the file is replaced
# atomically and keeps its permissions.
chrome_flag() {
    python3 - "$1/Local State" "$CHROME_FLAG" "$2" "${3:-}" <<'EOF_PY'
import json, os, re, sys, tempfile
path, flag, action, value = sys.argv[1:5]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
browser = data.get("browser") if isinstance(data.get("browser"), dict) else {}
labs = browser.get("enabled_labs_experiments")
labs = labs if isinstance(labs, list) else []
mine = re.compile("^" + re.escape(flag) + r"(@\d+)?$")
hits = [x for x in labs if isinstance(x, str) and mine.match(x)]
rest = [x for x in labs if not (isinstance(x, str) and mine.match(x))]
if action == "status":
    print("DISABLED" if any(x.endswith("@2") for x in hits) else ("ENABLED" if hits else "not set"))
    sys.exit(0)
new = rest + ([flag + "@" + value] if action == "set" else [])
if new:
    browser["enabled_labs_experiments"] = new
else:
    browser.pop("enabled_labs_experiments", None)
if browser:
    data["browser"] = browser
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".Local State.")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(data, f, separators=(",", ":"), ensure_ascii=False)
os.chmod(tmp, os.stat(path).st_mode & 0o7777)
os.replace(tmp, path)
EOF_PY
}

# Older versions changed the flag through chromium-pipewire-camera (camera-relay
# from Andycodeman/samsung-galaxy-book-linux-fixes) and recorded "chrome-flag";
# --undo still hands those back to it.
chromium_flag_tool() {
    if [[ -x /usr/local/bin/chromium-pipewire-camera ]]; then
        echo /usr/local/bin/chromium-pipewire-camera
    elif command -v chromium-pipewire-camera &>/dev/null; then
        command -v chromium-pipewire-camera
    else
        return 1
    fi
}

# Chrome-family browsers installed but never opened: no Local State yet, so
# nothing to change. "label<TAB>command" for each native one found that way
# (snap and Flatpak ones make their folders when first started too; they're
# left out, as their commands aren't on PATH the same way).
chrome_unopened() {
    local entry cmd dir label
    for entry in "google-chrome-stable:google-chrome:Google Chrome" \
                 "google-chrome-beta:google-chrome-beta:Google Chrome Beta" \
                 "google-chrome-unstable:google-chrome-unstable:Google Chrome Dev" \
                 "chromium:chromium:Chromium" "chromium-browser:chromium:Chromium" \
                 "brave:BraveSoftware/Brave-Browser:Brave" "brave-browser:BraveSoftware/Brave-Browser:Brave" \
                 "vivaldi:vivaldi:Vivaldi" "vivaldi-stable:vivaldi:Vivaldi" "opera:opera:Opera"; do
        cmd=${entry%%:*}; dir=${entry#*:}; label=${dir#*:}; dir=${dir%%:*}
        command -v "$cmd" &>/dev/null || continue
        [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/$dir/Local State" ]] && continue
        printf '%s\t%s\n' "$label" "$cmd"
    done | sort -u -t$'\t' -k1,1
    return 0
}

# Browsers that use the camera through PipeWire with nothing to set: GNOME
# Web (WebKitGTK always goes through PipeWire and the portal). One label each.
pipewire_native_browsers() {
    if command -v epiphany &>/dev/null || [[ -d "$HOME/.local/share/flatpak/app/org.gnome.Epiphany" ]] \
       || [[ -d /var/lib/flatpak/app/org.gnome.Epiphany ]]; then
        echo "GNOME Web"
    fi
    return 0
}

# ── Microsoft Edge ────────────────────────────────────────────────────────────
# Edge doesn't list the PipeWire camera in edge://flags, so there's nothing to
# set in its Local State, but the feature is built in: started with
# --enable-features=WebRtcPipeWireCamera it uses the PipeWire camera (checked
# on EndeavourOS, 23 Nov 2026). So the switch goes where Edge's launcher reads
# its start-up switches:
#   - the AUR package's launcher (Arch, EndeavourOS, CachyOS) reads
#     $XDG_CONFIG_HOME/microsoft-edge-<channel>-flags.conf: the whole file,
#     split on spaces (no comments), passed before the command line;
#   - Microsoft's own packages don't: there it goes into a copy of Edge's menu
#     entry in ~/.local/share/applications, marked as ours, which hides the
#     system's entry until removed.
# Chromium takes only the last --enable-features, so the feature is added to
# an existing list rather than given as a second switch. Edge doesn't rewrite
# either file, so it needn't be closed: the change applies at its next start.
EDGE_FEATURE="WebRtcPipeWireCamera"
EDGE_MARK="X-PipeWire-Browser-Camera-Fix=true"

# "label<TAB>command" for each Edge channel installed.
edge_launchers() {
    local entry
    for entry in "microsoft-edge-stable:Microsoft Edge" "microsoft-edge-beta:Microsoft Edge Beta" \
                 "microsoft-edge-dev:Microsoft Edge Dev"; do
        command -v "${entry%%:*}" &>/dev/null && printf '%s\t%s\n' "${entry#*:}" "${entry%%:*}"
    done
    return 0
}

# The flags file this channel's launcher reads, if it reads one.
edge_flags_file() {
    local launcher
    launcher=$(command -v "$1" 2>/dev/null) || return 1
    grep -qsF -- "$1-flags.conf" "$launcher" || return 1
    echo "${XDG_CONFIG_HOME:-$HOME/.config}/$1-flags.conf"
}

# Microsoft's menu entry for this channel: microsoft-edge.desktop for stable.
edge_desktop_name() {
    case "$1" in
        microsoft-edge-stable) echo microsoft-edge.desktop ;;
        *)                     echo "$1.desktop" ;;      # microsoft-edge-beta.desktop, -dev
    esac
}
edge_user_desktop() { echo "${XDG_DATA_HOME:-$HOME/.local/share}/applications/$(edge_desktop_name "$1")"; }
edge_system_desktop() {
    local dir name
    name=$(edge_desktop_name "$1")
    local IFS=:
    for dir in ${EDGE_DATA_DIRS:-${XDG_DATA_DIRS:-/usr/local/share:/usr/share}}; do
        [[ -f "$dir/applications/$name" ]] && { echo "$dir/applications/$name"; return 0; }
    done
    return 1
}

# edge_features MODE FILE KIND: MODE status (prints on/off), on or off; KIND
# flags (the whole file) or desktop (its Exec= lines). on and off rewrite the
# file atomically, keeping its mode; on creates a missing flags file.
edge_features() {
    python3 - "$@" "$EDGE_FEATURE" <<'EOF_PY'
import os, re, sys, tempfile
mode, path, kind, feature = sys.argv[1:5]
try:
    text = open(path, encoding="utf-8").read()
except FileNotFoundError:
    text = ""
token = re.compile(r"(--enable-features=)(\S*)")

def has(line):
    return any(feature in m.group(2).split(",") for m in token.finditer(line))

def edit(line):
    if mode == "off":
        def drop(m):
            rest = [f for f in m.group(2).split(",") if f and f != feature]
            return m.group(1) + ",".join(rest) if rest else ""
        new = token.sub(drop, line)
        return re.sub(r"[ \t]{2,}", " ", new).rstrip(" \t") if new != line else line
    if has(line):
        return line
    matches = list(token.finditer(line))
    if matches:                      # add to the last list: Chromium uses the last one
        m = matches[-1]
        joined = m.group(2) + ("," if m.group(2) else "") + feature
        return line[:m.start(2)] + joined + line[m.end(2):]
    return None                      # no list on this line

lines = text.split("\n")
if kind == "flags":
    on = has(text)
    if mode == "status":
        print("on" if on else "off"); sys.exit(0)
    if mode == "on" and not on:
        for i in range(len(lines) - 1, -1, -1):
            if token.search(lines[i]):
                lines[i] = edit(lines[i]); break
        else:
            if lines and lines[-1] == "":
                lines.pop()
            lines += ["--enable-features=" + feature, ""]
    elif mode == "off":
        lines = [edit(l) for l in lines]
        lines = [l for i, l in enumerate(lines) if l.strip() or i == len(lines) - 1]
else:
    execs = [i for i, l in enumerate(lines) if l.startswith("Exec=")]
    on = bool(execs) and all(has(lines[i]) for i in execs)
    if mode == "status":
        print("on" if on else "off"); sys.exit(0)
    for i in execs:
        new = edit(lines[i])
        if new is None:              # Exec=program args: the switch goes after the program
            prog, _, args = lines[i][5:].partition(" ")
            new = "Exec=" + prog + " --enable-features=" + feature + (" " + args if args else "")
        lines[i] = new
out = "\n".join(lines)
d = os.path.dirname(path) or "."
os.makedirs(d, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=d, prefix="." + os.path.basename(path) + ".")
with os.fdopen(fd, "w", encoding="utf-8") as f:
    f.write(out)
    f.flush(); os.fsync(f.fileno())
os.chmod(tmp, os.stat(path).st_mode & 0o7777 if os.path.exists(path) else 0o644)
os.replace(tmp, path)
EOF_PY
}

# Edge's state for one channel: "on|off VIA FILE", VIA flags-file, menu-entry
# (FILE: our copy, or the system entry it would be made from) or none.
edge_state() {
    local cmd="$1" file user
    if file=$(edge_flags_file "$cmd"); then
        echo "$(edge_features status "$file" flags 2>/dev/null || echo off) flags-file $file"
        return 0
    fi
    user=$(edge_user_desktop "$cmd")
    if [[ -f "$user" ]]; then
        echo "$(edge_features status "$user" desktop 2>/dev/null || echo off) menu-entry $user"
    elif file=$(edge_system_desktop "$cmd"); then
        echo "off menu-entry $file"
    else
        echo "off none -"
    fi
}

# edge_set CMD on|off LABEL: one line, ✓ or ⚠; recorded for --undo as
# "edge-flags <before> <present|absent> <file>" or "edge-desktop <file>".
edge_set() {
    local cmd="$1" want="$2" label="$3" file user sys before existed
    if ! command -v python3 &>/dev/null; then
        echo "⚠ $label: can't change its start-up switches without python3"; return 1
    fi
    if file=$(edge_flags_file "$cmd"); then
        before=$(edge_features status "$file" flags 2>/dev/null) || before=off
        if [[ "$before" == "$want" ]]; then echo "✓ $label: already $want"; return 0; fi
        [[ -e "$file" ]] && existed=present || existed=absent
        if edge_features "$want" "$file" flags 2>/dev/null; then
            recorded edge "$file" || record "edge-flags $before $existed $file"
            # Nothing left in it (it was ours, or held only the switch): no
            # file, which is what an empty one means to the launcher anyway.
            [[ "$want" == off && -z "$(tr -d '[:space:]' < "$file")" ]] && rm -f "$file"
            echo "✓ $label: PipeWire camera switch $([[ "$want" == on ]] && echo added to || echo removed from) ${file/#$HOME/\~}. It takes effect the next time Edge starts."
            return 0
        fi
        echo "⚠ $label: could not update ${file/#$HOME/\~}"; return 1
    fi
    user=$(edge_user_desktop "$cmd")
    if [[ "$want" == on ]]; then
        if [[ -f "$user" ]] && ! grep -qxF "$EDGE_MARK" "$user"; then
            if [[ "$(edge_features status "$user" desktop 2>/dev/null)" == on ]]; then echo "✓ $label: already on"; return 0; fi
            echo "⚠ $label: you have your own copy of its menu entry (${user/#$HOME/\~}). Add --enable-features=$EDGE_FEATURE to its Exec= lines by hand."
            return 1
        fi
        if [[ -f "$user" ]]; then echo "✓ $label: already on"; return 0; fi
        if ! sys=$(edge_system_desktop "$cmd"); then
            echo "⚠ $label: no menu entry to copy. Start it with --enable-features=$EDGE_FEATURE."; return 1
        fi
        mkdir -p "${user%/*}" && { cat "$sys"; echo "$EDGE_MARK"; } > "$user.tmp.$$" && mv -f "$user.tmp.$$" "$user" \
            && edge_features on "$user" desktop 2>/dev/null || { rm -f "$user.tmp.$$" "$user"; echo "⚠ $label: could not write ${user/#$HOME/\~}"; return 1; }
        recorded edge "$user" || record "edge-desktop $user"
        echo "✓ $label: PipeWire camera switch added to its menu entry (${user/#$HOME/\~}). It takes effect the next time Edge is started from the menu."
        return 0
    fi
    if [[ ! -f "$user" ]]; then echo "✓ $label: already off"; return 0; fi
    if ! grep -qxF "$EDGE_MARK" "$user"; then
        echo "⚠ $label: the switch is in your own copy of its menu entry (${user/#$HOME/\~}): remove it there by hand."
        return 1
    fi
    rm -f "$user" && { echo "✓ $label: our copy of its menu entry removed; the system's entry is used again."; return 0; }
    echo "⚠ $label: could not remove ${user/#$HOME/\~}"; return 1
}

# ── Checks and fixes ──────────────────────────────────────────────────────────

check_environment() {
    section "Session"
    echo "  Desktop: ${XDG_CURRENT_DESKTOP:-unknown} (${XDG_SESSION_TYPE:-unknown})"
    local refused
    refused=$(journalctl --user -b -u xdg-desktop-portal.service --no-pager -q 2>/dev/null \
        | grep -c "Only the focused app is allowed to show a system access dialog" || true)
    if (( ${refused:-0} > 0 )); then
        echo "  Portal: GNOME refused the camera dialog $refused time(s) since boot."
        echo "    That is the \"Waiting for your permission\" hang — the portal"
        echo "    permission check below fixes it."
    fi
}

check_other_browsers() {
    local line label cmd state
    local -a unopened=() edges=() native=()
    mapfile -t unopened < <(chrome_unopened)
    mapfile -t edges < <(edge_launchers)
    mapfile -t native < <(pipewire_native_browsers)
    (( ${#unopened[@]} + ${#edges[@]} + ${#native[@]} )) || return 0
    section "Other browsers"
    for line in "${unopened[@]}"; do
        printf '  %-20s %s\n' "${line%%$'\t'*}:" "installed, never opened: open it once and close it, then run this again"
    done
    for label in "${native[@]}"; do
        printf '  %-20s %s\n' "$label:" "uses the camera through PipeWire by itself: nothing to set"
    done
    for line in "${edges[@]}"; do
        label=${line%%$'\t'*}; cmd=${line#*$'\t'}
        state=$(edge_state "$cmd")
        case "$state" in
            on*)         printf '  %-20s %s\n' "$label:" "PipeWire camera switch ON (${state#* })" ;;
            "off none"*) printf '  %-20s %s\n' "$label:" "no flags file or menu entry to add the switch to: start it with --enable-features=$EDGE_FEATURE" ;;
            *)           printf '  %-20s %s\n' "$label:" "PipeWire camera switch off (Edge has no flags-page entry for it)"
                         [[ "$MODE" == check ]] && continue
                         if ask "Add the PipeWire camera switch to $label (${state#* })?"; then
                             edge_set "$cmd" on "$label" | sed 's/^/  /'
                         fi ;;
        esac
    done
}

check_chromium_flag() {
    section "Chrome / Chromium PipeWire camera flag"
    local -a profiles=() turn_on=() disabled=()
    local line label dir state
    mapfile -t profiles < <(chrome_profiles)
    if (( ${#profiles[@]} == 0 )); then
        echo "  No Chrome or Chromium profile found."
        return 0
    fi
    if ! command -v python3 &>/dev/null; then
        echo "  Can't read the profiles without python3. Open"
        echo "  chrome://flags/#$CHROME_FLAG, set it to Enabled, then fully quit and"
        echo "  reopen the browser."
        return 0
    fi
    for line in "${profiles[@]}"; do
        label=${line%%$'\t'*}
        dir=${line#*$'\t'}
        state=$(chrome_flag "$dir" status 2>/dev/null) || state="unreadable"
        printf '  %-20s %s\n' "$label:" "$state"
        case "$state" in
            "not set") turn_on+=("$line") ;;
            DISABLED)  disabled+=("$line") ;;
        esac
    done
    (( ${#turn_on[@]} + ${#disabled[@]} )) || return 0
    [[ "$MODE" == "check" ]] && return 0

    local -a change=()
    if (( ${#turn_on[@]} )) && ask "Enable the PipeWire camera flag in the browsers above that don't have it?"; then
        change+=("${turn_on[@]}")
    fi
    # Disabled may be a choice someone made: like a stored portal "no", this
    # always asks, even under --yes.
    for line in "${disabled[@]}"; do
        if ask_always "${line%%$'\t'*} has the flag set to Disabled. Enable it?"; then
            change+=("$line")
        fi
    done

    local before
    for line in "${change[@]}"; do
        label=${line%%$'\t'*}
        dir=${line#*$'\t'}
        if chrome_running "$dir"; then
            echo "  ⚠ $label is running. It rewrites its settings when it quits and would"
            echo "    undo this. Quit it completely (tray icon too), then run this again."
            continue
        fi
        before=$(chrome_flag "$dir" status 2>/dev/null) || before=""
        [[ -e "$dir/Local State$CHROME_BACKUP_SUFFIX" ]] \
            || cp -p "$dir/Local State" "$dir/Local State$CHROME_BACKUP_SUFFIX" 2>/dev/null || true
        if chrome_flag "$dir" set 1 2>/dev/null; then
            recorded chrome "$dir" || record "chrome ${before// /-} $dir"
            echo "  ✓ $label: flag enabled (backup: Local State$CHROME_BACKUP_SUFFIX)"
        else
            echo "  ⚠ $label: could not update Local State"
        fi
    done
}

# Snap Firefox can't use PipeWire cameras: inside the snap, its PipeWire library
# can't load PipeWire's own plugins ("pw_loop_new(): can't make support.system
# handle"), and Firefox crashes when a site asks for the camera. There the pref
# stays off, and Firefox uses the V4L2 camera (Camera Relay's loopback device).
snap_profile() { [[ "$1" == "$HOME"/snap/* ]]; }
flatpak_profile() { [[ "$1" == "$HOME"/.var/app/* ]]; }

# The value Firefox uses for the pref in this profile, and where it comes from,
# as "VALUE SOURCE": user.js, then prefs.js, then the native package's own
# default ("distro": Fedora turns it on), then Firefox's ("default": off).
# $2 is the package default's value (firefox_system_default), or empty.
firefox_effective() {
    local prefs="$1" sys_value="${2:-}" user_js value
    user_js=$(firefox_user_js_value "$prefs")
    value=$(firefox_pref_value "$prefs")
    if [[ -n "$user_js" ]]; then
        echo "$user_js user.js"
    elif [[ -n "$value" ]]; then
        echo "$value prefs.js"
    elif [[ -n "$sys_value" ]] && ! snap_profile "$prefs" && ! flatpak_profile "$prefs"; then
        echo "$sys_value distro"
    else
        echo "false default"
    fi
}

# Short label for the status list, like the Chrome lines: "Firefox",
# "Firefox (snap)", "Firefox (flatpak)". $2 set: also name the profile, for
# when one kind of Firefox has more than one profile in use.
firefox_status_label() {
    local prefs="$1" kind=""
    case "$prefs" in
        "$HOME"/snap/*)     kind=" (snap)" ;;
        "$HOME"/.var/app/*) kind=" (flatpak)" ;;
    esac
    if [[ -n "${2:-}" ]]; then
        local dir=${prefs%/prefs.js}
        printf 'Firefox%s [%s]' "$kind" "${dir##*/}"
    else
        printf 'Firefox%s' "$kind"
    fi
}

check_firefox_pref() {
    section "Firefox PipeWire camera pref ($FF_PREF)"
    local -a files=() used=() turn_on=() turn_off=()
    local -A per_kind=()
    local prefs value user_js effective used_root unused_root="" label status kind
    local sys sys_value="" snaps=0 unused=0 user_js_set=0
    mapfile -t files < <(firefox_prefs_files)
    if (( ${#files[@]} == 0 )); then
        if firefox_installed; then
            # A new install: Firefox makes its profile the first time it opens.
            echo "  Firefox hasn't been opened yet, so it has no settings to change."
            echo "  Open Firefox once and close it, then run this again."
        else
            echo "  No Firefox profile found."
        fi
        return 0
    fi
    sys=$(firefox_system_default)
    [[ -n "$sys" ]] && sys_value=${sys%% *}

    # Profiles Firefox doesn't read are counted, not listed.
    for prefs in "${files[@]}"; do
        if used_root=$(firefox_unused_profile "$prefs"); then
            unused=$((unused + 1))
            unused_root=$used_root
            continue
        fi
        used+=("$prefs")
        kind=$(firefox_status_label "$prefs")
        per_kind[$kind]=$(( ${per_kind[$kind]:-0} + 1 ))
    done

    for prefs in "${used[@]}"; do
        user_js=$(firefox_user_js_value "$prefs")
        effective=$(firefox_effective "$prefs" "$sys_value")
        effective=${effective%% *}

        kind=$(firefox_status_label "$prefs")
        if (( ${per_kind[$kind]} > 1 )); then
            label=$(firefox_status_label "$prefs" named)
            firefox_default_profile "$prefs" && label+=" (default)"
        else
            label=$kind
        fi
        if [[ "$effective" == true ]]; then status="ENABLED"; else status="DISABLED"; fi
        [[ -n "$user_js" ]] && status+=" (set in user.js)"
        printf '  %-20s %s\n' "$label:" "$status"

        if snap_profile "$prefs"; then
            snaps=1
            if [[ "$effective" == "true" ]]; then
                if [[ -n "$user_js" ]]; then user_js_set=1; else turn_off+=("$prefs"); fi
            fi
        elif [[ "$effective" != "true" ]]; then
            if [[ -n "$user_js" ]]; then user_js_set=1; else turn_on+=("$prefs"); fi
        fi
    done
    if (( unused )); then
        # Firefox 147+ ignores ~/.config/mozilla while ~/.mozilla exists.
        echo "  ($unused unused profile(s) skipped: Firefox reads ${unused_root/#$HOME/\~})"
    fi
    if (( user_js_set )); then
        echo "  A user.js sets the pref the other way and wins over prefs.js at every"
        echo "  start, so this script won't change it. Edit that user.js line by hand."
    fi
    if (( snaps )); then
        echo "  Snap Firefox crashes on the PipeWire camera (its PipeWire library can't"
        echo "  load its plugins inside the snap), so the pref stays off there and"
        echo "  Firefox uses the V4L2 camera (Camera Relay's loopback device)."
    fi
    (( ${#turn_on[@]} + ${#turn_off[@]} )) || return 0
    [[ "$MODE" == "check" ]] && return 0

    local -a change=() to=()
    if (( ${#turn_off[@]} )) && ask "Turn the pref off in the snap profiles above?"; then
        for prefs in "${turn_off[@]}"; do change+=("$prefs"); to+=(false); done
    fi
    if (( ${#turn_on[@]} )) && ask "Turn the pref on in the other profiles above that don't have it?"; then
        for prefs in "${turn_on[@]}"; do change+=("$prefs"); to+=(true); done
    fi
    (( ${#change[@]} )) || return 0
    if firefox_running; then
        echo "  ⚠ Firefox is running. It rewrites prefs.js when it quits and would"
        echo "    undo this. Quit Firefox completely, then run this again."
        return 0
    fi
    local i
    for i in "${!change[@]}"; do
        prefs=${change[$i]}
        value=$(firefox_pref_value "$prefs")
        if firefox_set_pref "$prefs" "${to[$i]}"; then
            recorded firefox "$prefs" || record "firefox $prefs ${value:-unset}"
            if [[ "${to[$i]}" == true ]]; then
                echo "  ✓ $(profile_label "$prefs"): pref on (backup: prefs.js$FF_BACKUP_SUFFIX)"
            else
                echo "  ✓ $(profile_label "$prefs"): pref off (backup: prefs.js$FF_BACKUP_SUFFIX)"
            fi
        else
            echo "  ⚠ $(profile_label "$prefs"): could not update prefs.js"
        fi
    done
}

check_portal() {
    section "Portal camera permission"
    local entries id state noid
    local -a ids=() unset_ids=() denied_ids=()

    if ! entries=$(portal_camera_entries); then
        echo "  Permission store not reachable (no busctl, session bus or xdg-desktop-portal)."
        return 0
    fi
    mapfile -t ids < <(browser_portal_app_ids)
    # The empty ID: apps the portal can't name (no app-<ID> systemd unit, as
    # for Firefox on LXQt). Only shown when something is stored for it; never
    # allowed by --yes, as it covers every such app, not only browsers.
    noid=$(portal_camera_state "$entries" "")
    if (( ${#ids[@]} == 0 )) && [[ -z "$noid" ]]; then
        echo "  No Chrome, Chromium or snap browser found — nothing needed."
        return 0
    fi

    for id in "${ids[@]}"; do
        state=$(portal_camera_state "$entries" "$id")
        case "$state" in
            yes) printf '  %-28s allowed\n' "$id:" ;;
            "")  printf '  %-28s not set\n' "$id:"; unset_ids+=("$id") ;;
            *)   printf '  %-28s %s (refused without asking)\n' "$id:" "$state"; denied_ids+=("$id") ;;
        esac
    done
    if [[ -n "$noid" ]]; then
        case "$noid" in
            yes) printf '  %-28s allowed\n' "(no app ID):" ;;
            *)   printf '  %-28s %s (refused without asking)\n' "(no app ID):" "$noid"; denied_ids+=("") ;;
        esac
        echo "  (no app ID) is for apps the portal can't name, such as Firefox on desktops"
        echo "  that don't start apps in their own systemd unit (LXQt, for one)."
    fi
    if (( ${#unset_ids[@]} )); then
        echo "  On GNOME, \"not set\" means the browser waits forever at \"Waiting for"
        echo "  your permission\": GNOME won't show the portal's dialog for it."
    fi
    [[ "$MODE" == "check" ]] && return 0

    if (( ${#unset_ids[@]} )) && \
       ask "Allow ${unset_ids[*]} to use the camera without the portal dialog? (The browser still asks per site.)"; then
        for id in "${unset_ids[@]}"; do
            if portal_store SetPermission sbssas devices true camera "$id" 1 yes &>/dev/null; then
                recorded portal "$id" || record "portal $id"
                echo "  ✓ $id: allowed"
            else
                echo "  ⚠ $id: could not store the permission"
            fi
        done
    fi

    # A "no" may be a choice the user made, or a stale denial left by a portal
    # crash (Andycodeman/samsung-galaxy-book-linux-fixes#37). Only a person can
    # tell which, so this always asks — even under --yes.
    for id in "${denied_ids[@]}"; do
        if ask_always "${id:-(no app ID)} has a stored \"no\". Remove it and allow the camera?"; then
            if portal_store SetPermission sbssas devices true camera "$id" 1 yes &>/dev/null; then
                recorded portal "$id" || record "portal-was-no $id"
                echo "  ✓ ${id:-(no app ID)}: allowed"
            else
                echo "  ⚠ ${id:-(no app ID)}: could not change the permission"
            fi
        fi
    done
}

# Put back what the state file records. A record is only dropped once its
# change is undone, or there's nothing left to undo (the profile is gone, or
# the setting was changed since). Every other one is kept, with what went
# wrong, and --undo exits 1, so running it again retries just those. The file
# is rewritten once, at the end: interrupted, the whole record is still there.
undo_changes() {
    if [[ ! -s "$STATE_FILE" && -s "$LEGACY_STATE_FILE" ]]; then
        STATE_FILE="$LEGACY_STATE_FILE"
    fi
    if [[ ! -s "$STATE_FILE" ]]; then
        echo "Nothing to undo — this script hasn't changed anything."
        return 0
    fi
    local line kind rest entries id plabel prefs prev tool dir state out failed=0
    local -a keep=()

    # undo_failed LINE MESSAGE: the change couldn't be undone; say why and keep it.
    undo_failed() {
        keep+=("$1")
        echo "  ⚠ $2"
        failed=$((failed + 1))
    }

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS=' ' read -r kind rest <<< "$line"
        case "$kind" in
            portal | portal-was-no)
                id="$rest"
                plabel=${id:-(no app ID)}
                # Asked again for each record: an earlier one may have changed
                # the store.
                if ! entries=$(portal_camera_entries); then
                    undo_failed "$line" "Portal: permission store not reachable — couldn't put back $plabel"
                    continue
                fi
                state=$(portal_camera_state "$entries" "$id")
                if [[ "$state" != "yes" ]]; then
                    # Not what this script set: changed since, or removed.
                    echo "  – Portal: $plabel is ${state:-not set} now, left as it is"
                    continue
                fi
                if [[ "$kind" == portal ]]; then
                    if portal_store DeletePermission sss devices camera "$id" &>/dev/null; then
                        echo "  ✓ Portal: removed the permission for $plabel"
                    else
                        undo_failed "$line" "Portal: couldn't remove the permission for $plabel"
                    fi
                elif portal_store SetPermission sbssas devices true camera "$id" 1 no &>/dev/null; then
                    echo "  ✓ Portal: $plabel back to \"no\""
                else
                    undo_failed "$line" "Portal: couldn't set $plabel back to \"no\""
                fi ;;
            firefox)
                prefs="${rest% *}"
                prev="${rest##* }"
                [[ -f "$prefs" ]] || { echo "  – $prefs is gone, nothing to put back"; continue; }
                if firefox_running; then
                    undo_failed "$line" "Firefox is running — quit it and run --undo again to restore $(profile_label "$prefs")"
                    continue
                fi
                if firefox_set_pref "$prefs" "$prev"; then
                    echo "  ✓ $(profile_label "$prefs"): pref back to ${prev}"
                else
                    undo_failed "$line" "$(profile_label "$prefs"): couldn't put the pref back to ${prev}"
                fi ;;
            edge-flags)
                # "edge-flags <on|off before> <present|absent before> <file>"
                prev=${rest%% *}; rest=${rest#* }; state=${rest%% *}; prefs=${rest#* }
                if [[ ! -e "$prefs" && "$prev" == off ]]; then
                    echo "  – ${prefs/#$HOME/\~} is gone, nothing to put back"; continue
                fi
                if edge_features "$prev" "$prefs" flags 2>/dev/null; then
                    if [[ "$prev" == off && -z "$(tr -d '[:space:]' < "$prefs")" ]]; then
                        rm -f "$prefs"
                    fi
                    echo "  ✓ Edge: PipeWire camera switch $([[ "$prev" == on ]] && echo back in || echo taken out of) ${prefs/#$HOME/\~}"
                else
                    undo_failed "$line" "Edge: couldn't put ${prefs/#$HOME/\~} back"
                fi ;;
            edge-desktop)
                # "edge-desktop <our copy of Edge's menu entry>"
                if [[ ! -f "$rest" ]]; then
                    echo "  – ${rest/#$HOME/\~} is gone, nothing to put back"
                elif ! grep -qxF "$EDGE_MARK" "$rest"; then
                    echo "  – ${rest/#$HOME/\~} isn't ours any more, left as it is"
                elif rm -f "$rest"; then
                    echo "  ✓ Edge: our copy of its menu entry removed"
                else
                    undo_failed "$line" "Edge: couldn't remove ${rest/#$HOME/\~}"
                fi ;;
            chrome)
                # "chrome <state before> <profile folder>"
                prev="${rest%% *}"
                dir="${rest#* }"
                [[ -f "$dir/Local State" ]] || { echo "  – ${dir/#$HOME/\~} is gone, nothing to put back"; continue; }
                if chrome_running "$dir"; then
                    undo_failed "$line" "The browser using ${dir/#$HOME/\~} is running — quit it and run --undo again"
                    continue
                fi
                case "$prev" in
                    DISABLED)
                        if chrome_flag "$dir" set 2; then
                            echo "  ✓ ${dir/#$HOME/\~}: flag back to Disabled"
                        else
                            undo_failed "$line" "${dir/#$HOME/\~}: couldn't set the flag back to Disabled"
                            continue
                        fi ;;
                    ENABLED)
                        # Enabled before a --disable turned it off.
                        if chrome_flag "$dir" set 1; then
                            echo "  ✓ ${dir/#$HOME/\~}: flag back to Enabled"
                        else
                            undo_failed "$line" "${dir/#$HOME/\~}: couldn't set the flag back to Enabled"
                            continue
                        fi ;;
                    *)
                        if chrome_flag "$dir" remove; then
                            echo "  ✓ ${dir/#$HOME/\~}: flag back to Default"
                        else
                            undo_failed "$line" "${dir/#$HOME/\~}: couldn't set the flag back to Default"
                            continue
                        fi ;;
                esac
                rm -f "$dir/Local State$CHROME_BACKUP_SUFFIX" ;;
            chrome-flag)
                # Recorded by versions that used chromium-pipewire-camera. It
                # undoes only what it set itself (its own markers); without it
                # there's nothing left to hand this to.
                if ! tool=$(chromium_flag_tool); then
                    echo "  – chromium-pipewire-camera isn't installed any more: nothing to hand back"
                    continue
                fi
                if out=$("$tool" disable 2>&1); then
                    sed 's/^ */  /' <<< "$out"
                else
                    sed 's/^ */  /' <<< "$out"
                    undo_failed "$line" "chromium-pipewire-camera disable didn't finish (above)"
                fi ;;
            *)
                # Written by a newer version, perhaps: not ours to drop.
                undo_failed "$line" "Unknown record, kept: $line" ;;
        esac
    done < "$STATE_FILE"

    if (( ${#keep[@]} )); then
        local tmp
        if tmp=$(mktemp "$STATE_FILE.XXXXXX") && printf '%s\n' "${keep[@]}" > "$tmp" \
           && mv -f "$tmp" "$STATE_FILE"; then
            :
        else
            rm -f "${tmp:-}"
            echo "  ⚠ Couldn't update $STATE_FILE: it still lists everything, so --undo again is safe"
        fi
        echo
        echo "$failed change(s) couldn't be put back, and are still recorded."
        echo "Fix what's listed above, then run: $0 --undo"
        return 1
    fi
    rm -f "$STATE_FILE"
    rmdir "${STATE_FILE%/*}" 2>/dev/null || true
    return 0
}

# ── For other programs: --status, --enable, --disable ─────────────────────────

# One tab-separated line per thing found, "KIND<TAB>key=value<TAB>…", for a
# settings window to read. Changes nothing. Lines (keys may be added later;
# readers should ignore ones they don't know):
#   chrome         label= target=<profile folder> flag=on|off|disabled|unreadable running=yes|no
#                  (Microsoft Edge: target=<its command>, via=flags-file|menu-entry|none,
#                  flag=manual when via=none: no file to add the switch to)
#   chrome-none    (no Chrome-family profile)        no-python   (can't read them)
#   chrome-unopened label= (installed, never opened: no settings yet)
#   pipewire-native label= (uses the camera through PipeWire with nothing to set: GNOME Web)
#   firefox        label= target=<prefs.js> pref=on|off from=user.js|prefs.js|distro|default
#                  distro=on|off|none kind=native|snap|flatpak profile=<folder name>
#                  default=yes|no running=yes|no
#   firefox-none   installed=yes|no (no profile: never opened, or not installed)
#   firefox-unused count=N reads=<folder Firefox uses instead>
#   portal         id=<app ID> state=yes|no|ask|unset (id empty: apps the portal
#                  can't name, such as Firefox on LXQt; listed only when stored)
#   portal-none    (no browser needing it)          portal-unreachable
status_report() {
    local line label dir state prefs eff sys sys_value="" distro kind
    local entries id
    local -a profiles=() files=()

    mapfile -t profiles < <(chrome_profiles)
    if (( ${#profiles[@]} == 0 )); then
        echo "chrome-none"
    elif ! command -v python3 &>/dev/null; then
        echo "no-python"
    else
        for line in "${profiles[@]}"; do
            label=${line%%$'\t'*}
            dir=${line#*$'\t'}
            state=$(chrome_flag "$dir" status 2>/dev/null) || state="unreadable"
            case "$state" in
                ENABLED)   state=on ;;
                DISABLED)  state=disabled ;;
                "not set") state=off ;;
                *)         state=unreadable ;;
            esac
            printf 'chrome\tlabel=%s\ttarget=%s\tflag=%s\trunning=%s\n' "$label" "$dir" "$state" \
                "$(chrome_running "$dir" && echo yes || echo no)"
        done
    fi

    # Edge, as a chrome line: flag is its start-up switch, via says where it
    # goes (flags-file, menu-entry, or none: no button), target is the command
    # for --enable/--disable. Edge doesn't rewrite either file, so running=no.
    local edge_line cmd estate
    while IFS= read -r edge_line; do
        [[ -n "$edge_line" ]] || continue
        cmd=${edge_line#*$'\t'}
        estate=$(edge_state "$cmd")
        set -- $estate
        printf 'chrome\tlabel=%s\ttarget=%s\tflag=%s\tvia=%s\trunning=no\n' "${edge_line%%$'\t'*}" "$cmd" \
            "$([[ "$2" == none ]] && echo manual || echo "$1")" "$2"
    done < <(edge_launchers)
    while IFS= read -r line; do
        [[ -n "$line" ]] && printf 'chrome-unopened\tlabel=%s\n' "${line%%$'\t'*}"
    done < <(chrome_unopened)
    while IFS= read -r label; do
        [[ -n "$label" ]] && printf 'pipewire-native\tlabel=%s\n' "$label"
    done < <(pipewire_native_browsers)

    mapfile -t files < <(firefox_prefs_files)
    if (( ${#files[@]} == 0 )); then
        printf 'firefox-none\tinstalled=%s\n' "$(firefox_installed && echo yes || echo no)"
    else
        sys=$(firefox_system_default)
        [[ -n "$sys" ]] && sys_value=${sys%% *}
        local unused=0 unused_root="" used_root running
        running=$(firefox_running && echo yes || echo no)
        for prefs in "${files[@]}"; do
            if used_root=$(firefox_unused_profile "$prefs"); then
                unused=$((unused + 1)); unused_root=$used_root
                continue
            fi
            if snap_profile "$prefs"; then kind=snap
            elif flatpak_profile "$prefs"; then kind=flatpak
            else kind=native; fi
            distro=none
            if [[ "$kind" == native && -n "$sys_value" ]]; then
                [[ "$sys_value" == true ]] && distro=on || distro=off
            fi
            eff=$(firefox_effective "$prefs" "$sys_value")
            dir=${prefs%/prefs.js}
            printf 'firefox\tlabel=%s\ttarget=%s\tpref=%s\tfrom=%s\tdistro=%s\tkind=%s\tprofile=%s\tdefault=%s\trunning=%s\n' \
                "$(firefox_status_label "$prefs")" "$prefs" \
                "$([[ "${eff%% *}" == true ]] && echo on || echo off)" "${eff#* }" "$distro" "$kind" \
                "${dir##*/}" "$(firefox_default_profile "$prefs" && echo yes || echo no)" "$running"
        done
        (( unused )) && printf 'firefox-unused\tcount=%d\treads=%s\n' "$unused" "$unused_root"
    fi

    if ! entries=$(portal_camera_entries); then
        echo "portal-unreachable"
    else
        local -a ids=()
        local noid
        mapfile -t ids < <(browser_portal_app_ids)
        noid=$(portal_camera_state "$entries" "")
        if (( ${#ids[@]} == 0 )) && [[ -z "$noid" ]]; then
            echo "portal-none"
        fi
        for id in "${ids[@]}"; do
            state=$(portal_camera_state "$entries" "$id")
            printf 'portal\tid=%s\tstate=%s\n' "$id" "${state:-unset}"
        done
        # Apps the portal can't name (Firefox on LXQt): only when stored.
        [[ -n "$noid" ]] && printf 'portal\tid=\tstate=%s\n' "$noid"
    fi
    return 0
}

# --allow ID: a portal "yes" for one app ID the script lists itself (a
# browser's, from browser_portal_app_ids), or for the empty ID (apps the portal
# can't name) only when a "no" is stored there: a "yes" there covers every such
# app, so it's never added from nothing. Recorded like --yes and the
# stored-"no" question, so --undo puts back what was there. One line, ✓ or ⚠.
portal_allow() {
    local id="$1" label="${1:-(no app ID)}" entries state known=0 x
    if ! entries=$(portal_camera_entries); then
        echo "⚠ $label: the permission store isn't reachable (no busctl, session bus or xdg-desktop-portal)"
        return 1
    fi
    state=$(portal_camera_state "$entries" "$id")
    if [[ -n "$id" ]]; then
        while IFS= read -r x; do [[ "$x" == "$id" ]] && known=1; done < <(browser_portal_app_ids)
    elif [[ "$state" == no ]]; then
        known=1
    fi
    if (( ! known )); then
        if [[ -z "$id" ]]; then
            echo "⚠ (no app ID): nothing refused there to clear"
        else
            echo "⚠ Not a browser app ID this script found: $id"
        fi
        return 1
    fi
    if [[ "$state" == yes ]]; then
        echo "✓ $label: already allowed"
        return 0
    fi
    if ! portal_store SetPermission sbssas devices true camera "$id" 1 yes &>/dev/null; then
        echo "⚠ $label: could not store the permission"
        return 1
    fi
    if [[ -n "$state" ]]; then
        recorded portal "$id" || record "portal-was-no $id"
    else
        recorded portal "$id" || record "portal $id"
    fi
    echo "✓ $label: allowed"
}

# --enable / --disable: change only the targets named, each a profile this
# script finds itself (nothing else is touched, whatever path is given).
# "on" sets the flag or pref on; "off" puts it back to the browser's own
# default (snap Firefox: off, as it crashes on PipeWire). The state before the
# first change is recorded, so --undo still goes back to it. One line per
# target, ✓ or ⚠ with the reason; exits 1 if any target wasn't changed.
set_targets() {
    local item want target line dir prefs before value eff label to sys sys_value="" failed=0
    local -a flag_args=()
    local -A chrome_dirs=() chrome_labels=() firefox_files=()
    sys=$(firefox_system_default)
    [[ -n "$sys" ]] && sys_value=${sys%% *}
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        chrome_dirs[${line#*$'\t'}]=1
        chrome_labels[${line#*$'\t'}]=${line%%$'\t'*}
    done < <(chrome_profiles)
    while IFS= read -r prefs; do
        [[ -n "$prefs" ]] && firefox_files[$prefs]=1
    done < <(firefox_prefs_files)
    local -A edge_cmds=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && edge_cmds[${line#*$'\t'}]=${line%%$'\t'*}
    done < <(edge_launchers)

    for item in "${SET_TARGETS[@]}"; do
        want=${item%% *}
        target=${item#* }
        if [[ "$want" == allow ]]; then
            portal_allow "$target" || failed=1
            continue
        fi
        if [[ -n "${edge_cmds[$target]:-}" ]]; then
            edge_set "$target" "$want" "${edge_cmds[$target]}" || failed=1
            continue
        fi
        # A folder given with a trailing slash, or through a link, is still the profile.
        if [[ -d "$target" ]]; then
            target=$(cd "$target" 2>/dev/null && pwd -P) || target=${item#* }
        fi
        if [[ -n "${chrome_dirs[$target]:-}" ]]; then
            label=${chrome_labels[$target]}
            dir=$target
            if ! command -v python3 &>/dev/null; then
                echo "⚠ $label: can't change the flag without python3"; failed=1; continue
            fi
            if chrome_running "$dir"; then
                echo "⚠ $label is running. It rewrites its settings when it quits and would undo this. Quit it completely (tray icon too), then try again."
                failed=1; continue
            fi
            before=$(chrome_flag "$dir" status 2>/dev/null) || before=""
            if [[ -z "$before" ]]; then
                echo "⚠ $label: couldn't read its Local State"; failed=1; continue
            fi
            if { [[ "$want" == on && "$before" == ENABLED ]] || [[ "$want" == off && "$before" == "not set" ]]; }; then
                echo "✓ $label: already $([[ "$want" == on ]] && echo on || echo at Default)"
                continue
            fi
            [[ -e "$dir/Local State$CHROME_BACKUP_SUFFIX" ]] \
                || cp -p "$dir/Local State" "$dir/Local State$CHROME_BACKUP_SUFFIX" 2>/dev/null || true
            if [[ "$want" == on ]]; then flag_args=(set 1); else flag_args=(remove); fi
            if chrome_flag "$dir" "${flag_args[@]}" 2>/dev/null; then
                recorded chrome "$dir" || record "chrome ${before// /-} $dir"
                echo "✓ $label: flag $([[ "$want" == on ]] && echo enabled || echo back to Default)"
            else
                echo "⚠ $label: could not update Local State"; failed=1
            fi
        elif [[ -n "${firefox_files[$target]:-}" ]]; then
            prefs=$target
            label=$(profile_label "$prefs")
            if firefox_unused_profile "$prefs" >/dev/null; then
                echo "⚠ $label: Firefox doesn't use this profile"; failed=1; continue
            fi
            if [[ -n "$(firefox_user_js_value "$prefs")" ]]; then
                echo "⚠ $label: a user.js sets the pref and wins over prefs.js at every start. Edit that user.js line by hand."
                failed=1; continue
            fi
            if snap_profile "$prefs"; then
                if [[ "$want" == on ]]; then
                    echo "⚠ $label: snap Firefox crashes on the PipeWire camera, so the pref stays off there (it uses the V4L2 camera)."
                    failed=1; continue
                fi
                to=false
            elif [[ "$want" == on ]]; then
                to=true
            else
                to="unset"
            fi
            value=$(firefox_pref_value "$prefs")
            if [[ "${value:-unset}" == "$to" ]]; then
                echo "✓ $label: already $([[ "$to" == true ]] && echo on || echo off)"
                continue
            fi
            if firefox_running; then
                echo "⚠ Firefox is running. It rewrites prefs.js when it quits and would undo this. Quit Firefox completely, then try again."
                failed=1; continue
            fi
            if firefox_set_pref "$prefs" "$to"; then
                recorded firefox "$prefs" || record "firefox $prefs ${value:-unset}"
                eff=$(firefox_effective "$prefs" "$sys_value")
                case "$to" in
                    true)  echo "✓ $label: pref on" ;;
                    false) echo "✓ $label: pref off" ;;
                    *)     echo "✓ $label: pref back to Firefox's default ($([[ "${eff%% *}" == true ]] && echo on || echo off))" ;;
                esac
            else
                echo "⚠ $label: could not update prefs.js"; failed=1
            fi
        else
            echo "⚠ Not a browser profile this script found: $target"
            failed=1
        fi
    done
    return "$failed"
}

# ── Main ──────────────────────────────────────────────────────────────────────

case "$MODE" in
    status) status_report; exit ;;
    set)    set_targets; exit ;;
esac

echo "pipewire-browser-camera-fix — Chrome, Chromium and Firefox on the PipeWire camera path"

if [[ "$MODE" == "undo" ]]; then
    undo_changes
    exit
fi

check_environment
check_chromium_flag
check_other_browsers
check_firefox_pref
check_portal

echo
if [[ "$MODE" == "check" ]]; then
    echo "Checked only — nothing was changed. Run without --check to fix."
else
    echo "Done. Quit each browser completely and reopen it from the app menu"
    echo "(not from a terminal — a browser started from a terminal can take the"
    echo "terminal's identity, and GNOME refuses the portal dialog for it)."
    if command -v galaxybook-camera &>/dev/null; then
        echo "Still no camera? Run: galaxybook-camera doctor"
    elif command -v camera-relay &>/dev/null; then
        echo "Still no camera? Run: camera-relay doctor"
    fi
    echo "To put back what this script changed: $0 --undo"
fi
