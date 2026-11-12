#!/usr/bin/env bash
# pipewire-browser-camera-fix.sh — get the camera working again in Chrome,
# Chromium and Firefox when they use it through PipeWire.
# https://github.com/david-bartlett/pipewire-browser-camera-fix
#
# Checks three things and, with your OK, fixes them:
#
#   1. Chrome / Chromium PipeWire camera flag
#      (chrome://flags/#enable-webrtc-pipewire-camera). Done through
#      chromium-pipewire-camera when it's installed (it comes with camera-relay
#      from Andycodeman/samsung-galaxy-book-linux-fixes); otherwise the script
#      says how to set the flag by hand.
#   2. Firefox PipeWire camera pref (media.webrtc.camera.allow-pipewire): on,
#      except in snap Firefox, which crashes on the PipeWire camera, so there
#      it's turned off.
#   3. xdg-desktop-portal camera permission for the browsers GNOME cannot show
#      the "allow camera?" dialog for. See the README for why: on GNOME, Chrome
#      and snap browsers wait forever at "Waiting for your permission", and the
#      user journal shows "Only the focused app is allowed to show a system
#      access dialog".
#
# Usage: pipewire-browser-camera-fix.sh [--check | --yes | --undo]
#
#   (none)    check, then ask before each change
#   --check   check only, change nothing
#   --yes     make every safe change without asking (never removes a stored
#             "no" from the portal — that one always asks)
#   --undo    put back everything this script changed
#
# Run it as yourself, not with sudo: it edits your browser profiles and talks
# to the portal on your session bus.

set -uo pipefail

STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/pipewire-browser-camera-fix/changes"
# Before the rename, changes were recorded here; --undo still reads it.
LEGACY_STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/browser-camera-fix/changes"
FF_PREF="media.webrtc.camera.allow-pipewire"
FF_BACKUP_SUFFIX=".pipewire-browser-camera-fix.bak"

PORTAL_STORE="org.freedesktop.impl.portal.PermissionStore"
PORTAL_STORE_PATH="/org/freedesktop/impl/portal/PermissionStore"

MODE="fix"
for arg in "$@"; do
    case "$arg" in
        --check) MODE="check" ;;
        --yes)   MODE="yes" ;;
        --undo)  MODE="undo" ;;
        -h|--help)
            sed -n '/^# Usage:/,/^# Run it/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
            exit 0 ;;
        *)
            echo "Unknown option: $arg (try --help)" >&2
            exit 2 ;;
    esac
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
        if command -v chromium &>/dev/null || command -v chromium-browser &>/dev/null; then
            echo "org.chromium.Chromium"
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

# Firefox rewrites prefs.js when it quits, so an edit made while it runs is lost.
firefox_running() {
    pgrep -u "$(id -u)" -x 'firefox|firefox-bin|firefox-esr|GeckoMain' &>/dev/null
}

# Set the pref to $2 (true/false), or remove it when $2 is "unset".
firefox_set_pref() {
    local prefs="$1" value="$2" tmp
    [[ -e "$prefs$FF_BACKUP_SUFFIX" ]] || cp -p "$prefs" "$prefs$FF_BACKUP_SUFFIX" || return 1
    tmp=$(mktemp "${prefs}.XXXXXX") || return 1
    grep -v "^[[:space:]]*user_pref(\"${FF_PREF//./\\.}\"" "$prefs" > "$tmp"
    if [[ "$value" != "unset" ]]; then
        echo "user_pref(\"$FF_PREF\", $value);" >> "$tmp"
    fi
    chmod --reference="$prefs" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$prefs"
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

# chromium-pipewire-camera comes with camera-relay
# (Andycodeman/samsung-galaxy-book-linux-fixes), installed to /usr/local/bin.
chromium_flag_tool() {
    if [[ -x /usr/local/bin/chromium-pipewire-camera ]]; then
        echo /usr/local/bin/chromium-pipewire-camera
    elif command -v chromium-pipewire-camera &>/dev/null; then
        command -v chromium-pipewire-camera
    else
        return 1
    fi
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

check_chromium_flag() {
    section "Chrome / Chromium PipeWire camera flag"
    local tool status
    if ! tool=$(chromium_flag_tool); then
        echo "  Can't check this one: chromium-pipewire-camera isn't installed (it comes"
        echo "  with camera-relay). Open chrome://flags/#enable-webrtc-pipewire-camera,"
        echo "  set it to Enabled, then fully quit and reopen the browser."
        return 0
    fi
    status=$("$tool" status 2>&1) || true
    if [[ -z "$status" || "$status" == *"No Chromium-family"* ]]; then
        echo "  No Chrome or Chromium profile found."
        return 0
    fi
    sed 's/^ */  /' <<< "$status"

    # Profile lines look like "  Google Chrome:      ENABLED".
    grep -E ':[[:space:]]' <<< "$status" | grep -qvE 'ENABLED[[:space:]]*$' || return 0
    [[ "$MODE" == "check" ]] && return 0

    if ask "Enable the PipeWire camera flag in the browsers above?"; then
        local out
        out=$("$tool" enable 2>&1) || true
        sed 's/^ */  /' <<< "$out"
        grep -q "PipeWire camera flag enabled" <<< "$out" && record "chrome-flag"
    fi
}

# Snap Firefox can't use PipeWire cameras: inside the snap, its PipeWire library
# can't load PipeWire's own plugins ("pw_loop_new(): can't make support.system
# handle"), and Firefox crashes when a site asks for the camera. There the pref
# stays off, and Firefox uses the V4L2 camera (Camera Relay's loopback device).
snap_profile() { [[ "$1" == "$HOME"/snap/* ]]; }
flatpak_profile() { [[ "$1" == "$HOME"/.var/app/* ]]; }

check_firefox_pref() {
    section "Firefox PipeWire camera pref ($FF_PREF)"
    local -a files=() turn_on=() turn_off=()
    local prefs value user_js shown effective used_root unused_root="" label sys sys_value="" sys_file=""
    local snaps=0 unused=0 user_js_set=0
    mapfile -t files < <(firefox_prefs_files)
    if (( ${#files[@]} == 0 )); then
        echo "  No Firefox profile found."
        return 0
    fi
    sys=$(firefox_system_default)
    if [[ -n "$sys" ]]; then
        sys_value=${sys%% *}
        sys_file=${sys#* }
    fi
    for prefs in "${files[@]}"; do
        value=$(firefox_pref_value "$prefs")
        user_js=$(firefox_user_js_value "$prefs")
        label=$(profile_label "$prefs")

        if [[ -n "$user_js" ]]; then
            effective=$user_js
            shown="(user.js, which overrides prefs.js)"
        elif [[ -n "$value" ]]; then
            effective=$value
            shown="(prefs.js)"
        elif [[ -n "$sys_value" ]] && ! snap_profile "$prefs" && ! flatpak_profile "$prefs"; then
            effective=$sys_value
            shown="(not in prefs.js; package default: $sys_file)"
        else
            effective=false
            shown="(not in prefs.js; Firefox default)"
        fi
        if [[ "$effective" == true ]]; then shown="on  $shown"; else shown="off $shown"; fi

        if used_root=$(firefox_unused_profile "$prefs"); then
            unused=1
            unused_root=$used_root
            printf '  %-44s %s — not used\n' "$label:" "$shown"
            continue
        fi
        # Only a profile Firefox reads can be its default: an unused folder's
        # installs.ini still names one of its own.
        firefox_default_profile "$prefs" && label+=" (default)"
        printf '  %-44s %s\n' "$label:" "$shown"

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
        echo "  \"not used\": Firefox reads its profiles from ${unused_root/#$HOME/\~} (since"
        echo "  Firefox 147 it ignores ~/.config/mozilla while ~/.mozilla exists), so the"
        echo "  profiles marked above make no difference. They are left alone."
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
            record "firefox $prefs ${value:-unset}"
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
    local entries id state
    local -a ids=() unset_ids=() denied_ids=()

    if ! entries=$(portal_camera_entries); then
        echo "  Permission store not reachable (no busctl, session bus or xdg-desktop-portal)."
        return 0
    fi
    mapfile -t ids < <(browser_portal_app_ids)
    if (( ${#ids[@]} == 0 )); then
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
    if (( ${#unset_ids[@]} )); then
        echo "  On GNOME, \"not set\" means the browser waits forever at \"Waiting for"
        echo "  your permission\": GNOME won't show the portal's dialog for it."
    fi
    [[ "$MODE" == "check" ]] && return 0

    if (( ${#unset_ids[@]} )) && \
       ask "Allow ${unset_ids[*]} to use the camera without the portal dialog? (The browser still asks per site.)"; then
        for id in "${unset_ids[@]}"; do
            if portal_store SetPermission sbssas devices true camera "$id" 1 yes &>/dev/null; then
                record "portal $id"
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
        if ask_always "$id has a stored \"no\". Remove it and allow the camera?"; then
            if portal_store SetPermission sbssas devices true camera "$id" 1 yes &>/dev/null; then
                record "portal-was-no $id"
                echo "  ✓ $id: allowed"
            else
                echo "  ⚠ $id: could not change the permission"
            fi
        fi
    done
}

undo_changes() {
    if [[ ! -s "$STATE_FILE" && -s "$LEGACY_STATE_FILE" ]]; then
        STATE_FILE="$LEGACY_STATE_FILE"
    fi
    if [[ ! -s "$STATE_FILE" ]]; then
        echo "Nothing to undo — this script hasn't changed anything."
        return 0
    fi
    local kind rest entries="" id prefs prev tool keep=()
    entries=$(portal_camera_entries) || entries=""

    while IFS=' ' read -r kind rest; do
        case "$kind" in
            portal)
                id="$rest"
                if [[ "$(portal_camera_state "$entries" "$id")" == "yes" ]] \
                   && portal_store DeletePermission sss devices camera "$id" &>/dev/null; then
                    echo "  ✓ Portal: removed the permission for $id"
                fi ;;
            portal-was-no)
                id="$rest"
                if [[ "$(portal_camera_state "$entries" "$id")" == "yes" ]] \
                   && portal_store SetPermission sbssas devices true camera "$id" 1 no &>/dev/null; then
                    echo "  ✓ Portal: $id back to \"no\""
                fi ;;
            firefox)
                prefs="${rest% *}"
                prev="${rest##* }"
                [[ -f "$prefs" ]] || continue
                if firefox_running; then
                    echo "  ⚠ Firefox is running — quit it and run --undo again to restore $(profile_label "$prefs")"
                    keep+=("$kind $rest")
                    continue
                fi
                firefox_set_pref "$prefs" "$prev" \
                    && echo "  ✓ $(profile_label "$prefs"): pref back to ${prev}" ;;
            chrome-flag)
                if tool=$(chromium_flag_tool); then
                    "$tool" disable 2>&1 | sed 's/^ */  /'
                fi ;;
        esac
    done < "$STATE_FILE"

    if (( ${#keep[@]} )); then
        printf '%s\n' "${keep[@]}" > "$STATE_FILE"
    else
        rm -f "$STATE_FILE"
        rmdir "${STATE_FILE%/*}" 2>/dev/null || true
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo "pipewire-browser-camera-fix — Chrome, Chromium and Firefox on the PipeWire camera path"

if [[ "$MODE" == "undo" ]]; then
    undo_changes
    exit 0
fi

check_environment
check_chromium_flag
check_firefox_pref
check_portal

echo
if [[ "$MODE" == "check" ]]; then
    echo "Checked only — nothing was changed. Run without --check to fix."
else
    echo "Done. Quit each browser completely and reopen it from the app menu"
    echo "(not from a terminal — a browser started from a terminal can take the"
    echo "terminal's identity, and GNOME refuses the portal dialog for it)."
    if command -v camera-relay &>/dev/null; then
        echo "Still no camera? Run: camera-relay doctor"
    fi
    echo "To put back what this script changed: $0 --undo"
fi
