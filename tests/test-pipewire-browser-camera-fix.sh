#!/usr/bin/env bash
# Tests for pipewire-browser-camera-fix.sh.
#
# What matters, and is easy to break silently:
#   1. Portal app IDs are the ones the portal really uses (Chrome's own scope
#      ID per channel, snap.<name>) — a grant under any other ID does nothing.
#   2. A stored "no" is never changed without a person saying so, even --yes.
#   3. Firefox prefs are never edited while Firefox runs (it rewrites prefs.js
#      on exit), and only the profiles that need it are touched: not profiles
#      Firefox doesn't use, not ones already on by the package's default, and
#      not ones where a user.js decides.
#   4. --undo puts back exactly what the script changed, and nothing else.
#   6. The Chrome flag is set in Local State directly, never while the browser
#      runs, never over a Disabled without asking, and --undo restores each
#      profile's own setting.
#   5. --check changes nothing.
#   8. prefs.js is never replaced by a part-written copy (a full disk).
#   7. --undo keeps every change it couldn't put back (a browser running, the
#      portal unreachable, a write that failed), says so and exits 1, so the
#      next --undo retries; and only the first record per profile is kept, so
#      --undo goes back to the state before the first run.
#
# Usage: ./test-pipewire-browser-camera-fix.sh
# Needs no browser, portal or session bus, and touches no system state.

set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pipewire-browser-camera-fix.sh"
PASS=0
FAIL=0

ok()  { echo "  ✓ $*"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

extract_fn() { sed -n "/^$1()/,/^}/p" "$SCRIPT"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "test-pipewire-browser-camera-fix ($SCRIPT)"

# ── Harness ───────────────────────────────────────────────────────────────────
# A fake home, a fake permission store behind a busctl stub ("ID|PERM" lines;
# the ID can be empty, as the portal stores apps it can't name),
# a fake chromium-pipewire-camera (only for old "chrome-flag" records), fake
# Chrome profiles (Local State files), and a PATH holding only the stubs plus the
# real tools the script uses — so this machine's own browsers can't leak in.
new_env() {
    local d="$TMP/env-$RANDOM$RANDOM" tool
    mkdir -p "$d/bin" "$d/home" "$d/proc" "$d/snap"
    : > "$d/store"
    for tool in sort head tail readlink mkdir rm rmdir cat sed wc mv cp mktemp chmod tr awk python3 ln sync id; do
        ln -s "$(command -v "$tool")" "$d/bin/$tool"
    done
    # grep, except when $d/prefs-write-fails exists: then the prefs.js filter
    # writes part of the file and fails, as on a full disk.
    cat > "$d/bin/grep" <<EOF
#!$BASH
if [[ -e "$d/prefs-write-fails" && "\$1" == -v && "\$2" == *allow-pipewire* ]]; then
    head -c 40 "\$3"; echo "grep: write error: No space left on device" >&2; exit 2
fi
exec $(command -v grep) "\$@"
EOF
    chmod +x "$d/bin/grep"
    cat > "$d/bin/busctl" <<EOF
#!$BASH
store="$d/store"
[[ -e "$d/unreachable" ]] && { echo "Failed to connect to bus" >&2; exit 1; }
while [[ \$# -gt 0 && "\$1" != call ]]; do shift; done
shift 4
method="\$1"; shift 2
echo "\$method \$*" >> "$d/calls"
case "\$method" in
    Lookup)
        [[ -s "\$store" ]] || { echo "Call failed: No entry for camera" >&2; exit 1; }
        out="a{sas}v \$(wc -l < "\$store")"
        while IFS="|" read -r id perm; do out+=" \"\$id\" 1 \"\$perm\""; done < "\$store"
        echo "\$out y 0" ;;
    SetPermission)
        [[ -e "$d/store-readonly" ]] && { echo "Call failed: refused" >&2; exit 1; }
        grep -v "^\$4|" "\$store" > "\$store.tmp"; mv "\$store.tmp" "\$store"
        echo "\$4|\$6" >> "\$store" ;;
    DeletePermission)
        [[ -e "$d/store-readonly" ]] && { echo "Call failed: refused" >&2; exit 1; }
        grep -v "^\$3|" "\$store" > "\$store.tmp"; mv "\$store.tmp" "\$store" ;;
esac
EOF
    # pgrep: "running" while $d/firefox-running exists.
    printf '#!%s\n[[ -e "%s/firefox-running" ]]\n' "$BASH" "$d" > "$d/bin/pgrep"
    printf '#!%s\nexit 0\n' "$BASH" > "$d/bin/journalctl"
    # Flag tool: status from $d/flag-status, enable/disable logged.
    cat > "$d/flag-tool" <<EOF
#!$BASH
echo "\$1" >> "$d/flag-calls"
case "\$1" in
    status)  cat "$d/flag-status" ;;
    enable)  echo "  ✓ Google Chrome: PipeWire camera flag enabled" ;;
    disable) [[ -e "$d/flag-fails" ]] && { echo "  ⚠ Google Chrome is running"; exit 1; }
             echo "  ✓ Google Chrome: PipeWire camera flag removed" ;;
esac
EOF
    chmod +x "$d/bin/busctl" "$d/bin/pgrep" "$d/bin/journalctl" "$d/flag-tool"
    echo "  Google Chrome:       ENABLED" > "$d/flag-status"
    printf '%s\n' "$d"
}

add_bin()   { printf '#!%s\n' "$BASH" > "$1/bin/$2"; chmod +x "$1/bin/$2"; }
# add_chrome ENV RELDIR 'JSON list of enabled_labs_experiments'
add_chrome() {
    mkdir -p "$1/home/$2"
    printf '{"browser":{"enabled_labs_experiments":%s},"other":{"keep":1}}' "${3:-[]}" > "$1/home/$2/Local State"
}
labs_of() { python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1])).get("browser",{}).get("enabled_labs_experiments",[])))' "$1/home/$2/Local State"; }
other_kept() { python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1])).get("other") != {"keep":1})' "$1/home/$2/Local State"; }
add_snap()  { mkdir -p "$1/snap/$2/current"; }
store_set() { echo "$2|$3" >> "$1/store"; }
perm_of()   { awk -F'|' -v id="$2" '$1 == id { print $2 }' "$1/store"; }
add_proc() {
    mkdir -p "$1/proc/$2"
    echo "$3" > "$1/proc/$2/cgroup"
    ln -s "$4" "$1/proc/$2/exe"
}
# add_profile ENV RELDIR [pref value]
add_profile() {
    mkdir -p "$1/home/$2"
    {
        echo '// Mozilla User Preferences'
        echo 'user_pref("browser.startup.page", 3);'
        [[ -n "${3:-}" ]] && echo "user_pref(\"media.webrtc.camera.allow-pipewire\", $3);"
    } > "$1/home/$2/prefs.js"
}
# system_default ENV FILE VALUE: a Firefox package's own default for the pref.
system_default() {
    mkdir -p "$1/sys/${2%/*}"
    echo "pref(\"media.webrtc.camera.allow-pipewire\", $3);" > "$1/sys/$2"
}
pref_in() { sed -n 's/^user_pref("media\.webrtc\.camera\.allow-pipewire", \(.*\));$/\1/p' "$1/home/$2/prefs.js"; }

# Run the script's checks (or --undo, --status) in env $1 with mode $2, stdin
# not a terminal. Mode "set" takes "on TARGET" / "off TARGET" items after it,
# as --enable / --disable do.
run() {
    local d="$1" mode="$2"
    shift 2
    # shellcheck disable=SC2034  # read by the evaluated set_targets
    local -a SET_TARGETS=("$@")
    (
        PATH="$d/bin"
        HOME="$d/home"
        unset XDG_STATE_HOME XDG_CONFIG_HOME XDG_DATA_HOME MOZ_LEGACY_HOME
        # shellcheck disable=SC2034  # read by firefox_system_default
        FF_SYSTEM_ROOT="$d/sys"
        # shellcheck disable=SC2034  # read by the evaluated functions
        MODE="$mode"
        eval "$(sed -n '/^STATE_FILE=/,/^PORTAL_STORE_PATH=/p' "$SCRIPT")"
        eval "$(grep -E '^(EDGE_(FEATURE|MARK)|PORTAL_STORED_ONLY|FLATPAK_BROWSER_IDS)=' "$SCRIPT")"
        # shellcheck disable=SC2034  # read by edge_system_desktop, chrome_installed
        EDGE_DATA_DIRS="$d/share" SNAP_ROOT_DIR="$d/snap" FLATPAK_SYSTEM_DIR="$d/flatpak"
        for fn in section answer_yes ask ask_always record recorded portal_store portal_camera_entries \
                  portal_camera_state portal_id_label running_chromium_scope_ids firefox_prefs_files \
                  firefox_pref_value firefox_running firefox_set_pref profile_label snap_profile \
                  flatpak_profile firefox_unused_profile firefox_default_profile \
                  firefox_system_default firefox_user_js_value firefox_status_label firefox_effective \
                  chrome_profiles chrome_installed chrome_running chrome_flag \
                  check_environment check_chromium_flag check_firefox_pref check_portal \
                  undo_changes status_report set_targets portal_allow portal_stored_only_ids \
                  chrome_unopened pipewire_native_browsers edge_launchers edge_flags_file edge_desktop_name \
                  edge_user_desktop edge_system_desktop edge_features edge_state edge_set check_other_browsers; do
            eval "$(extract_fn "$fn")"
        done
        eval "$(extract_fn browser_portal_app_ids | sed '1s/^browser_portal_app_ids()/real_ids()/')"
        browser_portal_app_ids() { real_ids "$d/proc" "$d/snap"; }
        eval "$(extract_fn firefox_installed | sed '1s/^firefox_installed()/real_ff_installed()/')"
        firefox_installed() { real_ff_installed "$d/snap"; }
        chromium_flag_tool() { echo "$d/flag-tool"; }
        case "$mode" in
            undo)   undo_changes ;;
            status) status_report ;;
            set)    set_targets ;;
            *)      check_environment; check_chromium_flag; check_other_browsers; check_firefox_pref; check_portal ;;
        esac
    ) < /dev/null > "$d/out" 2>&1
    echo $? > "$d/rc"
}
state_of() { cat "$1/home/.local/state/pipewire-browser-camera-fix/changes" 2>/dev/null; }

# ── 1. Portal app IDs ─────────────────────────────────────────────────────────
echo
echo "portal app IDs"

d=$(new_env)
add_bin "$d" google-chrome-stable
add_bin "$d" google-chrome-beta
add_bin "$d" chromium
add_snap "$d" firefox
add_snap "$d" spotify
add_proc "$d" 4242 "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-com.brave.Browser-4242.scope" /opt/brave.com/brave/brave
add_proc "$d" 5000 "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-org.gnome.Ptyxis-5000.scope" /usr/bin/ptyxis
add_proc "$d" 6000 "0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-gnome-firefox-6000.scope" /usr/lib/firefox/firefox
run "$d" yes
for id in com.google.Chrome com.google.Chrome.beta org.chromium.Chromium snap.firefox com.brave.Browser; do
    check "$id allowed" '[[ "$(perm_of "$d" "$id")" == yes ]]'
done
check "nothing under the .desktop name google-chrome" '[[ -z "$(perm_of "$d" google-chrome)" ]]'
check "non-browser snap ignored" '[[ -z "$(perm_of "$d" snap.spotify)" ]]'
check "terminal with a self-named scope ignored" '[[ -z "$(perm_of "$d" org.gnome.Ptyxis)" ]]'
check "launcher scope (app-gnome-…) not taken for a browser ID" '[[ -z "$(perm_of "$d" gnome-firefox)$(perm_of "$d" firefox)" ]]'

# ── 2. Stored decisions ───────────────────────────────────────────────────────
echo
echo "stored decisions"

d=$(new_env)
add_bin "$d" google-chrome-stable
add_bin "$d" chromium
store_set "$d" com.google.Chrome no
store_set "$d" org.chromium.Chromium yes
run "$d" yes
check "stored \"no\" untouched under --yes" '[[ "$(perm_of "$d" com.google.Chrome)" == no ]]'
check "the user's own \"yes\" not recorded as ours" '! grep -q org.chromium.Chromium <<< "$(state_of "$d")"'

d=$(new_env)
add_bin "$d" google-chrome-stable
touch "$d/unreachable"
run "$d" yes
check "unreachable store: exits 0" '[[ "$(cat "$d/rc")" == 0 ]]'
check "unreachable store: reported" 'grep -q "not reachable" "$d/out"'

# ── 3. Firefox ────────────────────────────────────────────────────────────────
echo
echo "Firefox pref"

d=$(new_env)
add_profile "$d" .mozilla/firefox/abc.default-release false
add_profile "$d" snap/firefox/common/.mozilla/firefox/def.default
add_profile "$d" .config/mozilla/firefox/ghi.default true
run "$d" yes
check "native profile set to true" '[[ "$(pref_in "$d" .mozilla/firefox/abc.default-release)" == true ]]'
check "snap profile not turned on (snap Firefox crashes on PipeWire)" '[[ -z "$(pref_in "$d" snap/firefox/common/.mozilla/firefox/def.default)" ]]'
check "snap: says why the pref stays off" 'grep -q "Snap Firefox crashes on the PipeWire camera" "$d/out"'
check "only one pref line left" '[[ $(grep -c allow-pipewire "$d/home/.mozilla/firefox/abc.default-release/prefs.js") == 1 ]]'
check "other prefs kept" 'grep -q "browser.startup.page" "$d/home/.mozilla/firefox/abc.default-release/prefs.js"'
check "backup made" '[[ -f "$d/home/.mozilla/firefox/abc.default-release/prefs.js.pipewire-browser-camera-fix.bak" ]]'
check "profile already on not touched" '[[ ! -e "$d/home/.config/mozilla/firefox/ghi.default/prefs.js.pipewire-browser-camera-fix.bak" ]]'
check "previous value recorded" 'grep -q "abc.default-release/prefs.js false" <<< "$(state_of "$d")"'
check "untouched snap profile not recorded" '! grep -q "def.default" <<< "$(state_of "$d")"'

d=$(new_env)
add_profile "$d" snap/firefox/common/.mozilla/firefox/def.default true
run "$d" yes
check "snap profile with the pref on turned off" '[[ "$(pref_in "$d" snap/firefox/common/.mozilla/firefox/def.default)" == false ]]'
check "snap: previous value recorded for --undo" 'grep -q "def.default/prefs.js true" <<< "$(state_of "$d")"'
run "$d" undo
check "snap: --undo puts the pref back on" '[[ "$(pref_in "$d" snap/firefox/common/.mozilla/firefox/def.default)" == true ]]'

d=$(new_env)
add_profile "$d" .mozilla/firefox/abc.default-release false
touch "$d/firefox-running"
run "$d" yes
check "Firefox running: prefs.js not edited" '[[ "$(pref_in "$d" .mozilla/firefox/abc.default-release)" == false ]]'
check "Firefox running: told to quit it" 'grep -q "Firefox is running" "$d/out"'

# Firefox 147+ ignores ~/.config/mozilla while ~/.mozilla exists, and Fedora's
# package turns the pref on by default (Fedora 45, KDE).
d=$(new_env)
add_profile "$d" .mozilla/firefox/txwhf7mb.default-release
printf '[Install11457493C5A56847]\nDefault=txwhf7mb.default-release\nLocked=1\n' \
    > "$d/home/.mozilla/firefox/installs.ini"
add_profile "$d" .config/mozilla/firefox/jidixcko.default-release false
printf '[Install11457493C5A56847]\nDefault=jidixcko.default-release\nLocked=1\n' \
    > "$d/home/.config/mozilla/firefox/installs.ini"
system_default "$d" usr/lib64/firefox/browser/defaults/preferences/firefox-redhat-default-prefs.js true
run "$d" yes
check "Fedora: unset pref shown as ENABLED, from the package default" \
    'grep -qx "  Firefox: *ENABLED" "$d/out"'
check "Fedora: profile already on by default not edited" \
    '[[ ! -e "$d/home/.mozilla/firefox/txwhf7mb.default-release/prefs.js.pipewire-browser-camera-fix.bak" ]]'
check "unused profile counted" 'grep -q "1 unused profile(s) skipped" "$d/out"'
check "unused profile not listed" '! grep -q "jidixcko" "$d/out"'
check "unused XDG profile not edited" '[[ "$(pref_in "$d" .config/mozilla/firefox/jidixcko.default-release)" == false ]]'
check "says which folder Firefox reads" 'grep -q "Firefox reads ~/.mozilla/firefox" "$d/out"'
check "nothing recorded" '[[ -z "$(state_of "$d")" ]]'

d=$(new_env)
add_profile "$d" .config/mozilla/firefox/xyz.default-release false
run "$d" yes
check "no ~/.mozilla: XDG profile is the one used, and turned on" \
    '[[ "$(pref_in "$d" .config/mozilla/firefox/xyz.default-release)" == true ]]'
check "no ~/.mozilla: nothing skipped" '! grep -q "unused profile" "$d/out"'

d=$(new_env)
add_profile "$d" .mozilla/firefox/abc.default-release
run "$d" yes
check "no package default: unset shown as DISABLED" 'grep -qx "  Firefox: *DISABLED" "$d/out"'
check "no package default: unset pref turned on" '[[ "$(pref_in "$d" .mozilla/firefox/abc.default-release)" == true ]]'

d=$(new_env)
add_profile "$d" .var/app/org.mozilla.firefox/.mozilla/firefox/fp.default-release
system_default "$d" usr/lib64/firefox/browser/defaults/preferences/firefox-redhat-default-prefs.js true
run "$d" yes
check "Flatpak: the native package's default doesn't apply" \
    '[[ "$(pref_in "$d" .var/app/org.mozilla.firefox/.mozilla/firefox/fp.default-release)" == true ]]'

d=$(new_env)
add_profile "$d" .mozilla/firefox/abc.default-release
echo 'user_pref("media.webrtc.camera.allow-pipewire", false);' > "$d/home/.mozilla/firefox/abc.default-release/user.js"
run "$d" yes
check "user.js wins: shown as such" 'grep -q "Firefox: *DISABLED (set in user.js)" "$d/out"'
check "user.js wins: prefs.js not edited" '[[ -z "$(pref_in "$d" .mozilla/firefox/abc.default-release)" ]]'
check "user.js wins: told to edit it by hand" 'grep -q "Edit that user.js line by hand" "$d/out"'

d=$(new_env)
add_profile "$d" .mozilla/firefox/old.default true
add_profile "$d" .mozilla/firefox/new.default true
printf '[Profile1]\nName=old\nIsRelative=1\nPath=old.default\n\n[Profile0]\nName=new\nIsRelative=1\nPath=new.default\nDefault=1\n\n[General]\nVersion=2\n' \
    > "$d/home/.mozilla/firefox/profiles.ini"
run "$d" check
check "no installs.ini: default from profiles.ini Default=1" 'grep -q "\[new.default\] (default):" "$d/out"'
check "no installs.ini: other profile not marked default" '! grep -q "\[old.default\] (default)" "$d/out"'

# ── 4. Chrome flag ────────────────────────────────────────────────────────────
echo
echo "Chrome / Chromium flag"
G=.config/google-chrome

d=$(new_env)
add_chrome "$d" "$G" '["enable-webrtc-pipewire-camera@1"]'
run "$d" yes
check "already ENABLED: nothing recorded" '[[ -z "$(state_of "$d")" ]]'
check "already ENABLED: no backup made" '[[ ! -e "$d/home/$G/Local State.pipewire-browser-camera-fix.bak" ]]'

d=$(new_env)
add_chrome "$d" "$G" '["other-flag@1"]'
add_chrome "$d" .config/BraveSoftware/Brave-Browser '[]'
run "$d" yes
check "not set: flag enabled" '[[ "$(labs_of "$d" "$G")" == "other-flag@1 enable-webrtc-pipewire-camera@1" ]]'
check "other flags and settings kept" 'other_kept "$d" "$G"'
check "Brave found and enabled too" '[[ "$(labs_of "$d" .config/BraveSoftware/Brave-Browser)" == "enable-webrtc-pipewire-camera@1" ]]'
check "recorded with the state before" 'grep -qx "chrome not-set $d/home/$G" <<< "$(state_of "$d")"'
check "backup made" '[[ -e "$d/home/$G/Local State.pipewire-browser-camera-fix.bak" ]]'
check "chromium-pipewire-camera not used" '[[ ! -e "$d/flag-calls" ]]'

d=$(new_env)
add_chrome "$d" "$G" '["enable-webrtc-pipewire-camera@2"]'
run "$d" yes
check "Disabled left alone under --yes (no one to ask)" '[[ "$(labs_of "$d" "$G")" == "enable-webrtc-pipewire-camera@2" ]]'
check "Disabled reported" 'grep -q "Google Chrome: *DISABLED" "$d/out"'

d=$(new_env)
add_chrome "$d" "$G" '[]'
ln -s "myhost-$$" "$d/home/$G/SingletonLock"   # this test's own pid: "running"
run "$d" yes
check "running browser not touched" '[[ -z "$(labs_of "$d" "$G")" ]]'
check "running browser: told to quit" 'grep -q "is running" "$d/out"'

d=$(new_env)
add_chrome "$d" "$G" '[]'
ln -s "myhost-999999999" "$d/home/$G/SingletonLock"   # stale lock after a crash
run "$d" yes
check "stale lock: flag enabled" '[[ "$(labs_of "$d" "$G")" == "enable-webrtc-pipewire-camera@1" ]]'

d=$(new_env)
mkdir -p "$d/home/snap/chromium/123/.config"
ln -s 123 "$d/home/snap/chromium/current"
add_chrome "$d" snap/chromium/123/.config/chromium '[]'
add_chrome "$d" .var/app/com.google.Chrome/config/google-chrome '[]'
run "$d" check
check "snap Chromium found once" '[[ "$(grep -c "Chromium (snap)" "$d/out")" == 1 ]]'
check "Flatpak Chrome found" 'grep -q "Google Chrome (flatpak): *not set" "$d/out"'

# ── 5. --check ────────────────────────────────────────────────────────────────
echo
echo "--check"

d=$(new_env)
add_bin "$d" google-chrome-stable
add_profile "$d" .mozilla/firefox/abc.default-release false
add_chrome "$d" "$G" '[]'
run "$d" check
check "no portal change" '! grep -q SetPermission "$d/calls" 2>/dev/null'
check "no Firefox change" '[[ "$(pref_in "$d" .mozilla/firefox/abc.default-release)" == false ]]'
check "no flag change" '[[ -z "$(labs_of "$d" "$G")" ]]'
check "nothing recorded" '[[ -z "$(state_of "$d")" ]]'
check "unset portal permission reported" 'grep -q "com.google.Chrome: *not set" "$d/out"'

# ── 6. --undo ─────────────────────────────────────────────────────────────────
echo
echo "--undo"

d=$(new_env)
add_bin "$d" google-chrome-stable
add_snap "$d" firefox
store_set "$d" org.mozilla.firefox yes
add_profile "$d" .mozilla/firefox/abc.default-release false
add_profile "$d" snap/firefox/common/.mozilla/firefox/def.default
add_chrome "$d" "$G" '["other-flag@1"]'
add_chrome "$d" .config/chromium '["enable-webrtc-pipewire-camera@1"]'
run "$d" yes
# A Disabled the script changed after asking, simulated in the state file.
add_chrome "$d" .config/vivaldi '["enable-webrtc-pipewire-camera@1"]'
echo "chrome DISABLED $d/home/.config/vivaldi" >> "$d/home/.local/state/pipewire-browser-camera-fix/changes"
# A "no" the script changed after asking, simulated in the state file.
store_set "$d" org.chromium.Chromium yes
echo "portal-was-no org.chromium.Chromium" >> "$d/home/.local/state/pipewire-browser-camera-fix/changes"
run "$d" undo
check "portal grants removed" '[[ -z "$(perm_of "$d" com.google.Chrome)$(perm_of "$d" snap.firefox)" ]]'
check "a \"no\" it changed is a \"no\" again" '[[ "$(perm_of "$d" org.chromium.Chromium)" == no ]]'
check "entry it never added kept" '[[ "$(perm_of "$d" org.mozilla.firefox)" == yes ]]'
check "Firefox pref back to false" '[[ "$(pref_in "$d" .mozilla/firefox/abc.default-release)" == false ]]'
check "snap profile still without the pref" '[[ -z "$(pref_in "$d" snap/firefox/common/.mozilla/firefox/def.default)" ]]'
check "Chrome flag back to Default" '[[ "$(labs_of "$d" "$G")" == "other-flag@1" ]]'
check "Chrome backup removed" '[[ ! -e "$d/home/$G/Local State.pipewire-browser-camera-fix.bak" ]]'
check "flag it didn't set kept (Chromium)" '[[ "$(labs_of "$d" .config/chromium)" == "enable-webrtc-pipewire-camera@1" ]]'
check "a Disabled it changed is Disabled again" '[[ "$(labs_of "$d" .config/vivaldi)" == "enable-webrtc-pipewire-camera@2" ]]'
check "state file removed" '[[ -z "$(state_of "$d")" ]]'

d=$(new_env)
run "$d" undo
check "--undo with nothing recorded says so" 'grep -q "Nothing to undo" "$d/out"'

# "chrome-flag" recorded by versions that used chromium-pipewire-camera.
d=$(new_env)
mkdir -p "$d/home/.local/state/pipewire-browser-camera-fix"
echo "chrome-flag" > "$d/home/.local/state/pipewire-browser-camera-fix/changes"
run "$d" undo
check "old chrome-flag record handed to chromium-pipewire-camera" 'grep -qx disable "$d/flag-calls"'

# Changes recorded before the rename live under browser-camera-fix/.
d=$(new_env)
store_set "$d" com.google.Chrome yes
mkdir -p "$d/home/.local/state/browser-camera-fix"
echo "portal com.google.Chrome" > "$d/home/.local/state/browser-camera-fix/changes"
run "$d" undo
check "--undo reads the pre-rename state file" '[[ -z "$(perm_of "$d" com.google.Chrome)" ]]'
check "pre-rename state file removed" '[[ ! -e "$d/home/.local/state/browser-camera-fix/changes" ]]'

# ── 7. --undo keeps what it couldn't put back ─────────────────────────────────
echo
echo "--undo: failures kept and retried"

ST=.local/state/pipewire-browser-camera-fix/changes
set_state() { mkdir -p "$1/home/${ST%/*}"; shift_d=$1; shift; printf '%s\n' "$@" > "$shift_d/home/$ST"; }
rc_of() { cat "$1/rc"; }

# Firefox and Chrome running, the portal fine: the portal is undone, the other
# two kept; once they're closed, a second --undo finishes.
d=$(new_env)
add_profile "$d" .mozilla/firefox/abc.default true
add_chrome "$d" "$G" '["enable-webrtc-pipewire-camera@1"]'
store_set "$d" com.google.Chrome yes
set_state "$d" "portal com.google.Chrome" "firefox $d/home/.mozilla/firefox/abc.default/prefs.js unset" \
    "chrome not-set $d/home/$G"
touch "$d/firefox-running"
ln -s "host-$$" "$d/home/$G/SingletonLock"
run "$d" undo
check "browsers running: exit 1" '[[ "$(rc_of "$d")" == 1 ]]'
check "browsers running: the portal grant is still removed" '[[ -z "$(perm_of "$d" com.google.Chrome)" ]]'
check "browsers running: only Firefox and Chrome still recorded" \
    '[[ "$(state_of "$d")" == "$(printf "%s\n" "firefox $d/home/.mozilla/firefox/abc.default/prefs.js unset" "chrome not-set $d/home/$G")" ]]'
check "browsers running: says how many weren't put back" 'grep -q "2 change(s) couldn.t be put back" "$d/out"'
rm -f "$d/firefox-running" "$d/home/$G/SingletonLock"
run "$d" undo
check "closed: second --undo exits 0" '[[ "$(rc_of "$d")" == 0 ]]'
check "closed: Firefox pref back to unset" '[[ -z "$(pref_in "$d" .mozilla/firefox/abc.default)" ]]'
check "closed: Chrome flag back to Default" '[[ -z "$(labs_of "$d" "$G")" ]]'
check "closed: state file removed" '[[ -z "$(state_of "$d")" ]]'

# The portal not reachable, then refusing changes, then fine.
d=$(new_env)
store_set "$d" snap.firefox yes
set_state "$d" "portal snap.firefox"
touch "$d/unreachable"
run "$d" undo
check "portal unreachable: kept, exit 1" '[[ "$(rc_of "$d")" == 1 && "$(state_of "$d")" == "portal snap.firefox" ]]'
check "portal unreachable: reported" 'grep -q "not reachable" "$d/out"'
rm -f "$d/unreachable"
touch "$d/store-readonly"
run "$d" undo
check "removal refused: kept, exit 1" '[[ "$(rc_of "$d")" == 1 && "$(state_of "$d")" == "portal snap.firefox" ]]'
rm -f "$d/store-readonly"
run "$d" undo
check "portal fine: undone, record gone" '[[ "$(rc_of "$d")" == 0 && -z "$(perm_of "$d" snap.firefox)" && -z "$(state_of "$d")" ]]'

d=$(new_env)
store_set "$d" snap.chromium yes
set_state "$d" "portal-was-no snap.chromium"
touch "$d/store-readonly"
run "$d" undo
check "\"no\" refused: kept, exit 1" '[[ "$(rc_of "$d")" == 1 && "$(state_of "$d")" == "portal-was-no snap.chromium" ]]'
rm -f "$d/store-readonly"
run "$d" undo
check "\"no\" put back on the retry" '[[ "$(perm_of "$d" snap.chromium)" == no && -z "$(state_of "$d")" ]]'

# Changed since (the user said "no" meanwhile): nothing of ours left to undo.
d=$(new_env)
store_set "$d" com.google.Chrome no
set_state "$d" "portal com.google.Chrome"
run "$d" undo
check "changed since: left as it is, record dropped, exit 0" \
    '[[ "$(rc_of "$d")" == 0 && "$(perm_of "$d" com.google.Chrome)" == no && -z "$(state_of "$d")" ]]'

# A Local State that can't be read now: kept, and left as it is.
d=$(new_env)
mkdir -p "$d/home/$G"
printf '{"browser":{"enabled_labs' > "$d/home/$G/Local State"
set_state "$d" "chrome DISABLED $d/home/$G"
run "$d" undo
check "Chrome write fails: kept, exit 1" '[[ "$(rc_of "$d")" == 1 && "$(state_of "$d")" == "chrome DISABLED $d/home/$G" ]]'
check "Chrome write fails: the file left as it was" '[[ "$(cat "$d/home/$G/Local State")" == "{\"browser\":{\"enabled_labs" ]]'

# chromium-pipewire-camera (old chrome-flag records) not finishing: kept.
d=$(new_env)
set_state "$d" "chrome-flag"
touch "$d/flag-fails"
run "$d" undo
check "chromium-pipewire-camera fails: kept, exit 1" '[[ "$(rc_of "$d")" == 1 && "$(state_of "$d")" == chrome-flag ]]'

# Gone profiles are dropped; a record this version doesn't know is kept.
d=$(new_env)
set_state "$d" "firefox $d/home/gone/prefs.js unset" "chrome not-set $d/home/gone" "frobnicate x y"
run "$d" undo
check "gone profiles dropped, unknown record kept" '[[ "$(rc_of "$d")" == 1 && "$(state_of "$d")" == "frobnicate x y" ]]'

# Only the first record per profile: the fix turns the pref on (recording
# "unset"), the user turns it off, the fix runs again. --undo goes back to
# unset, not to the in-between false.
echo
echo "first record kept"
d=$(new_env)
add_profile "$d" .mozilla/firefox/abc.default
run "$d" yes
check "first run records the original" '[[ "$(state_of "$d")" == "firefox $d/home/.mozilla/firefox/abc.default/prefs.js unset" ]]'
sed -i 's/allow-pipewire", true);/allow-pipewire", false);/' "$d/home/.mozilla/firefox/abc.default/prefs.js"
run "$d" yes
check "second run turns it on again" '[[ "$(pref_in "$d" .mozilla/firefox/abc.default)" == true ]]'
check "no second record" '[[ "$(state_of "$d")" == "firefox $d/home/.mozilla/firefox/abc.default/prefs.js unset" ]]'
run "$d" undo
check "--undo puts back the original (unset)" '[[ -z "$(pref_in "$d" .mozilla/firefox/abc.default)" ]]'

# ── 8. prefs.js only replaced by a whole copy ─────────────────────────────────
echo
echo "prefs.js on a full disk"

# The fix turning the pref on, while the filter's write fails.
d=$(new_env)
add_profile "$d" .mozilla/firefox/abc.default-release false
pf="$d/home/.mozilla/firefox/abc.default-release/prefs.js"
cp "$pf" "$d/prefs-before"
touch "$d/prefs-write-fails"
run "$d" yes
check "full disk: prefs.js unchanged" 'cmp -s "$d/prefs-before" "$pf"'
check "full disk: reported" 'grep -q "could not update prefs.js" "$d/out"'
check "full disk: no temporary file left" '[[ -z "$(find "${pf%/*}" -name "prefs.js.??????")" ]]'
check "full disk: nothing recorded for --undo" '! grep -q "abc.default-release" <<< "$(state_of "$d")"'
rm -f "$d/prefs-write-fails"
run "$d" yes
check "disk space back: the pref is set" '[[ "$(pref_in "$d" .mozilla/firefox/abc.default-release)" == true ]]'

# --undo while the write fails: prefs.js stays, and so does the record.
cp "$pf" "$d/prefs-before"
touch "$d/prefs-write-fails"
run "$d" undo
check "full disk, --undo: prefs.js unchanged" 'cmp -s "$d/prefs-before" "$pf"'
check "full disk, --undo: kept for the next --undo, exit 1" \
    '[[ "$(cat "$d/rc")" == 1 ]] && grep -q "abc.default-release/prefs.js false" <<< "$(state_of "$d")"'
rm -f "$d/prefs-write-fails"
run "$d" undo
check "--undo after: pref back to false" '[[ "$(pref_in "$d" .mozilla/firefox/abc.default-release)" == false ]]'

# A prefs.js with nothing but our line (grep keeps no lines: status 1, not an error).
d=$(new_env)
mkdir -p "$d/home/.mozilla/firefox/abc.default-release"
echo 'user_pref("media.webrtc.camera.allow-pipewire", false);' > "$d/home/.mozilla/firefox/abc.default-release/prefs.js"
run "$d" yes
check "prefs.js with only our line: set to true" '[[ "$(pref_in "$d" .mozilla/firefox/abc.default-release)" == true ]]'

# ── 9. --status, --enable, --disable (for a settings window) ──────────────────
echo
echo "--status, --enable, --disable"

# line_of ENV KIND TEXT: the --status line of that kind containing TEXT.
line_of() { grep -P "^$2\t" "$1/out" | grep -F -- "$3" | head -1; }
# field LINE KEY: one key=value field of a --status line.
field() { tr '\t' '\n' <<< "$1" | sed -n "s/^$2=//p"; }

G=.config/google-chrome
C=.config/chromium
d=$(new_env)
add_chrome "$d" "$G" '["enable-webrtc-pipewire-camera@1"]'
add_chrome "$d" "$C" '[]'
add_profile "$d" .mozilla/firefox/abc.default-release
add_profile "$d" snap/firefox/common/.mozilla/firefox/def.default
add_bin "$d" google-chrome-stable; add_bin "$d" chromium
run "$d" status
l=$(line_of "$d" chrome "$d/home/$G")
check "status: Chrome on, not running" '[[ "$(field "$l" flag)" == on && "$(field "$l" running)" == no && "$(field "$l" label)" == "Google Chrome" ]]'
l=$(line_of "$d" chrome "$d/home/$C")
check "status: Chromium off" '[[ "$(field "$l" flag)" == off ]]'
l=$(line_of "$d" firefox abc.default-release)
check "status: native Firefox off, from Firefox's default" \
    '[[ "$(field "$l" pref)" == off && "$(field "$l" from)" == default && "$(field "$l" kind)" == native && "$(field "$l" distro)" == none ]]'
check "status: target is the prefs.js" '[[ "$(field "$l" target)" == "$d/home/.mozilla/firefox/abc.default-release/prefs.js" ]]'
l=$(line_of "$d" firefox def.default)
check "status: snap Firefox listed as snap" '[[ "$(field "$l" kind)" == snap && "$(field "$l" label)" == "Firefox (snap)" ]]'
check "status: portal not set for Chrome" '[[ "$(field "$(line_of "$d" portal com.google.Chrome)" state)" == unset ]]'
check "status: no banner, only status lines" '! grep -qvP "^(chrome|chrome-none|chrome-unopened|pipewire-native|no-python|firefox|firefox-none|firefox-unused|portal|portal-none|portal-unreachable)(\t|$)" "$d/out"'
check "status: changes nothing" '[[ -z "$(state_of "$d")" && ! -e "$d/home/$C/Local State.pipewire-browser-camera-fix.bak" && -z "$(perm_of "$d" com.google.Chrome)" ]]'
touch "$d/firefox-running"; ln -s "myhost-$$" "$d/home/$G/SingletonLock"
run "$d" status
check "status: running browsers say so" \
    '[[ "$(field "$(line_of "$d" chrome "$d/home/$G")" running)" == yes && "$(field "$(line_of "$d" firefox abc.default)" running)" == yes ]]'
touch "$d/unreachable"
run "$d" status
check "status: portal unreachable" 'grep -qx portal-unreachable "$d/out"'

d=$(new_env)
run "$d" status
check "status: no browsers, Firefox not installed" 'grep -qx chrome-none "$d/out" && grep -qxP "firefox-none\tinstalled=no" "$d/out"'
add_bin "$d" firefox
run "$d" status
check "status: Firefox installed, never opened" 'grep -qxP "firefox-none\tinstalled=yes" "$d/out"'
run "$d" yes
check "check: Firefox never opened: told to open it once" 'grep -q "Open Firefox once and close it, then run this again" "$d/out"'

# Fedora: the package turns the pref on; turning it off removes ours, so it's on again.
d=$(new_env)
add_profile "$d" .mozilla/firefox/abc.default-release true
system_default "$d" usr/lib64/firefox/defaults/pref/firefox-redhat-default-prefs.js true
run "$d" status
# shellcheck disable=SC2034  # l is read by the check strings (eval)
l=$(line_of "$d" firefox abc.default-release)
check "status: Fedora's default shown as distro=on" '[[ "$(field "$l" distro)" == on && "$(field "$l" from)" == prefs.js ]]'
FP="$d/home/.mozilla/firefox/abc.default-release/prefs.js"
run "$d" set "off $FP"
check "disable on Fedora: our line removed, back to the package's on" \
    '[[ -z "$(pref_in "$d" .mozilla/firefox/abc.default-release)" ]] && grep -q "back to Firefox.s default (on)" "$d/out"'

# The Chrome flag, one profile at a time.
d=$(new_env)
add_chrome "$d" "$G" '[]'
add_chrome "$d" "$C" '[]'
run "$d" set "on $d/home/$G"
check "enable: Chrome flag on, exit 0" '[[ "$(labs_of "$d" "$G")" == "enable-webrtc-pipewire-camera@1" && "$(cat "$d/rc")" == 0 ]]'
check "enable: other browser untouched" '[[ -z "$(labs_of "$d" "$C")" ]]'
check "enable: rest of Local State kept" 'other_kept "$d" "$G"'
check "enable: recorded for --undo" '[[ "$(state_of "$d")" == "chrome not-set $d/home/$G" ]]'
run "$d" set "off $d/home/$G/"
check "disable (trailing slash): back to Default" '[[ -z "$(labs_of "$d" "$G")" ]]'
check "disable: still one record, the first state" '[[ "$(state_of "$d")" == "chrome not-set $d/home/$G" ]]'
run "$d" set "off $d/home/$G"
check "disable again: already at Default, exit 0" 'grep -q "already at Default" "$d/out" && [[ "$(cat "$d/rc")" == 0 ]]'

# A flag the user enabled themselves, turned off here: --undo turns it back on.
d=$(new_env)
add_chrome "$d" "$G" '["enable-webrtc-pipewire-camera@1"]'
run "$d" set "off $d/home/$G"
check "disable a hand-set flag: off, recorded as ENABLED" \
    '[[ -z "$(labs_of "$d" "$G")" && "$(state_of "$d")" == "chrome ENABLED $d/home/$G" ]]'
run "$d" undo
check "--undo: hand-set flag back to Enabled" '[[ "$(labs_of "$d" "$G")" == "enable-webrtc-pipewire-camera@1" ]]'

# A Disabled flag: an explicit --enable is the person saying so.
d=$(new_env)
add_chrome "$d" "$G" '["enable-webrtc-pipewire-camera@2"]'
run "$d" set "on $d/home/$G"
check "enable over Disabled: Enabled" '[[ "$(labs_of "$d" "$G")" == "enable-webrtc-pipewire-camera@1" ]]'
run "$d" undo
check "--undo: Disabled again" '[[ "$(labs_of "$d" "$G")" == "enable-webrtc-pipewire-camera@2" ]]'

# Chrome running: refused, nothing changed.
d=$(new_env)
add_chrome "$d" "$G" '[]'
ln -s "myhost-$$" "$d/home/$G/SingletonLock"
run "$d" set "on $d/home/$G"
check "Chrome running: refused, exit 1, says to quit it" \
    '[[ "$(cat "$d/rc")" == 1 && -z "$(labs_of "$d" "$G")" ]] && grep -q "Google Chrome is running" "$d/out"'
check "Chrome running: nothing recorded" '[[ -z "$(state_of "$d")" ]]'

# Firefox, one profile at a time.
d=$(new_env)
add_profile "$d" .mozilla/firefox/abc.default-release
add_profile "$d" snap/firefox/common/.mozilla/firefox/def.default true
FP="$d/home/.mozilla/firefox/abc.default-release/prefs.js"
SP="$d/home/snap/firefox/common/.mozilla/firefox/def.default/prefs.js"
run "$d" set "on $FP"
check "enable: Firefox pref on" '[[ "$(pref_in "$d" .mozilla/firefox/abc.default-release)" == true ]]'
check "enable: snap profile untouched" '[[ "$(pref_in "$d" snap/firefox/common/.mozilla/firefox/def.default)" == true ]]'
run "$d" set "off $FP"
check "disable: Firefox pref removed (Firefox's default)" '[[ -z "$(pref_in "$d" .mozilla/firefox/abc.default-release)" ]]'
check "disable: one record, the first state" '[[ "$(state_of "$d")" == "firefox $FP unset" ]]'
run "$d" set "on $SP"
check "enable snap Firefox: refused, exit 1" \
    '[[ "$(cat "$d/rc")" == 1 ]] && grep -q "snap Firefox crashes" "$d/out" && [[ "$(pref_in "$d" snap/firefox/common/.mozilla/firefox/def.default)" == true ]]'
run "$d" set "off $SP"
check "disable snap Firefox: set to false" '[[ "$(pref_in "$d" snap/firefox/common/.mozilla/firefox/def.default)" == false ]]'
touch "$d/firefox-running"
run "$d" set "on $FP"
check "Firefox running: refused, exit 1, prefs.js unchanged" \
    '[[ "$(cat "$d/rc")" == 1 && -z "$(pref_in "$d" .mozilla/firefox/abc.default-release)" ]] && grep -q "Firefox is running" "$d/out"'
rm -f "$d/firefox-running"
echo 'user_pref("media.webrtc.camera.allow-pipewire", false);' > "${FP%/prefs.js}/user.js"
run "$d" set "on $FP"
check "user.js decides: refused, exit 1" '[[ "$(cat "$d/rc")" == 1 ]] && grep -q "Edit that user.js line by hand" "$d/out"'

# Anything that isn't a profile the script finds is left alone.
d=$(new_env)
add_chrome "$d" "$G" '[]'
mkdir -p "$d/elsewhere"; printf '{"browser":{}}' > "$d/elsewhere/Local State"
run "$d" set "on $d/elsewhere" "on $d/home/$G"
check "unknown target: refused and untouched, exit 1" \
    '[[ "$(cat "$d/rc")" == 1 && "$(cat "$d/elsewhere/Local State")" == "{\"browser\":{}}" ]] && grep -q "Not a browser profile this script found" "$d/out"'
check "unknown target: the real one beside it still changed" '[[ "$(labs_of "$d" "$G")" == "enable-webrtc-pipewire-camera@1" ]]'

# A profile left behind by an uninstall isn't offered in --status.
d=$(new_env)
add_chrome "$d" .config/chromium '["enable-webrtc-pipewire-camera@1"]'
add_chrome "$d" "$G" '[]'
add_bin "$d" google-chrome
add_chrome "$d" snap/chromium/1/.config/chromium '[]'; ln -s 1 "$d/home/snap/chromium/current"
add_chrome "$d" .var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser '[]'
run "$d" status
check "status: Chromium's folder without Chromium installed: not listed" '[[ -z "$(line_of "$d" chrome "label=Chromium	")" ]]'
check "status: Chrome found by its other command (google-chrome)" '[[ -n "$(line_of "$d" chrome "label=Google Chrome	")" ]]'
check "status: snap and Flatpak folders without the snap or app: not listed" \
    '! grep -q "(snap)\|(flatpak)" "$d/out"'
add_snap "$d" chromium; mkdir -p "$d/flatpak/app/com.brave.Browser"
run "$d" status
check "status: with the snap and the Flatpak installed: listed" \
    '[[ -n "$(line_of "$d" chrome "Chromium (snap)")" && -n "$(line_of "$d" chrome "Brave (flatpak)")" ]]'
run "$d" check
check "check: still names the left-behind Chromium profile (it shows what it finds)" 'grep -q "^  Chromium:" "$d/out"'

# The empty app ID: apps the portal can't name (Firefox on LXQt).
d=$(new_env)
store_set "$d" "" yes
run "$d" status
check "status: a stored empty-ID entry is listed (id=), not portal-none" \
    'grep -qxP "portal\tid=\tstate=yes" "$d/out" && ! grep -qx portal-none "$d/out"'
run "$d" check
check "check: shown as (no app ID), with what it means" \
    'grep -q "(no app ID): *allowed" "$d/out" && grep -q "apps the portal can.t name" "$d/out"'
d=$(new_env)
run "$d" status
check "status: nothing stored, no browser: portal-none, no empty-ID line" \
    'grep -qx portal-none "$d/out" && ! grep -qP "^portal\tid=\t" "$d/out"'
add_bin "$d" google-chrome-stable
run "$d" yes
check "--yes never adds a \"yes\" for the empty ID (it covers every unnamed app)" \
    '[[ "$(perm_of "$d" com.google.Chrome)" == yes ]] && ! grep -q "^|" "$d/store"'
d=$(new_env)
store_set "$d" "" no
run "$d" yes
check "a stored \"no\" for the empty ID: untouched under --yes, reported" \
    '[[ "$(perm_of "$d" "")" == no ]] && grep -q "(no app ID): *no (refused without asking)" "$d/out"'
# As if a person had said yes to removing it: --undo puts the "no" back.
store_set "$d" "" yes; sed -i "/^|no$/d" "$d/store"
mkdir -p "$d/home/.local/state/pipewire-browser-camera-fix"
echo "portal-was-no " > "$d/home/.local/state/pipewire-browser-camera-fix/changes"
run "$d" undo
check "--undo: the empty ID back to \"no\", named as (no app ID)" \
    '[[ "$(perm_of "$d" "")" == no ]] && grep -q "Portal: (no app ID) back to \"no\"" "$d/out" && [[ -z "$(state_of "$d")" ]]'

# --allow: one portal app ID, for the tray's Allow button.
d=$(new_env)
add_bin "$d" google-chrome-stable
store_set "$d" com.google.Chrome no
run "$d" set "allow com.google.Chrome"
check "allow over a stored \"no\": yes, recorded as was-no, exit 0" \
    '[[ "$(perm_of "$d" com.google.Chrome)" == yes && "$(state_of "$d")" == "portal-was-no com.google.Chrome" && "$(cat "$d/rc")" == 0 ]]'
run "$d" set "allow com.google.Chrome"
check "allow again: already allowed, still one record" 'grep -q "already allowed" "$d/out" && [[ $(state_of "$d" | wc -l) == 1 ]]'
run "$d" undo
check "--undo: back to \"no\"" '[[ "$(perm_of "$d" com.google.Chrome)" == no ]]'
d=$(new_env)
add_bin "$d" google-chrome-stable
run "$d" set "allow com.google.Chrome"
check "allow when not set (GNOME's case): yes, recorded" '[[ "$(perm_of "$d" com.google.Chrome)" == yes && "$(state_of "$d")" == "portal com.google.Chrome" ]]'
run "$d" undo
check "--undo: the permission removed again" '[[ -z "$(perm_of "$d" com.google.Chrome)" ]]'
run "$d" set "allow org.example.NotABrowser"
check "allow an ID the script doesn't list: refused, nothing stored, exit 1" \
    '[[ "$(cat "$d/rc")" == 1 && -z "$(perm_of "$d" org.example.NotABrowser)" ]] && grep -q "Not a browser app ID" "$d/out"'
run "$d" set "allow "
check "allow the empty ID with nothing refused there: refused, nothing stored" \
    '[[ "$(cat "$d/rc")" == 1 ]] && ! grep -q "^|" "$d/store" && grep -q "nothing refused there" "$d/out"'
store_set "$d" "" no
run "$d" set "allow "
check "allow the empty ID over a stored \"no\": yes, recorded" \
    '[[ "$(perm_of "$d" "")" == yes && "$(state_of "$d")" == "portal-was-no " ]] && grep -q "(no app ID): allowed" "$d/out"'
run "$d" undo
check "--undo: the empty ID back to \"no\"" '[[ "$(perm_of "$d" "")" == no ]]'
touch "$d/unreachable"
run "$d" set "allow com.google.Chrome"
check "allow with the store unreachable: refused, exit 1" '[[ "$(cat "$d/rc")" == 1 ]] && grep -q "isn.t reachable" "$d/out"'

# Flatpak Chrome (Codex review 10): its ID is com.google.Chrome too, but with no
# native Chrome or running scope it wasn't listed, so a stored "no" was
# invisible and --allow refused it. Now shown (and allowed) when something is
# stored; "not set" stays hidden (GNOME's dialog works for a Flatpak).
d=$(new_env)
mkdir -p "$d/flatpak/app/com.google.Chrome"
add_chrome "$d" ".var/app/com.google.Chrome/config/google-chrome" '["enable-webrtc-pipewire-camera@1"]'
store_set "$d" com.google.Chrome no
run "$d" status
check "Flatpak Chrome: a stored \"no\" is listed" 'grep -qx $'"'"'portal\tid=com.google.Chrome\tstate=no'"'"' "$d/out"'
run "$d" set "allow com.google.Chrome"
check "Flatpak Chrome: --allow over the \"no\": yes, recorded" \
    '[[ "$(perm_of "$d" com.google.Chrome)" == yes && "$(state_of "$d")" == "portal-was-no com.google.Chrome" && "$(cat "$d/rc")" == 0 ]]'
d=$(new_env)
mkdir -p "$d/flatpak/app/com.google.Chrome"
run "$d" status
check "Flatpak Chrome, nothing stored: not listed (its dialog works)" '! grep -q "id=com.google.Chrome" "$d/out"'
run "$d" set "allow com.google.Chrome"
check "Flatpak Chrome, nothing stored: --allow refuses (nothing refused to clear)" \
    '[[ "$(cat "$d/rc")" == 1 && -z "$(perm_of "$d" com.google.Chrome)" ]]'
d=$(new_env)
mkdir -p "$d/flatpak/app/com.google.Chrome"
add_bin "$d" google-chrome-stable
store_set "$d" com.google.Chrome no
run "$d" status
check "native and Flatpak Chrome: com.google.Chrome listed once" '[[ $(grep -c "id=com.google.Chrome" "$d/out") == 1 ]]'

# ── Microsoft Edge, browsers never opened, GNOME Web ──────────────────────────
# edge_launcher ENV yes|no: microsoft-edge-stable, reading its flags file or not.
edge_launcher() {
    { printf '#!%s\n' "$BASH"; [[ "$2" == yes ]] && echo '# reads $XDG_CONFIG_HOME/microsoft-edge-stable-flags.conf'; } > "$1/bin/microsoft-edge-stable"
    chmod +x "$1/bin/microsoft-edge-stable"
}
EF() { echo "$1/home/.config/microsoft-edge-stable-flags.conf"; }

d=$(new_env)
edge_launcher "$d" yes
run "$d" status
# shellcheck disable=SC2034  # l is read by the check strings (eval)
l=$(line_of "$d" chrome "Microsoft Edge")
check "status: Edge listed (flags file), off, target its command" \
    '[[ "$(field "$l" flag)" == off && "$(field "$l" via)" == flags-file && "$(field "$l" target)" == microsoft-edge-stable && "$(field "$l" running)" == no ]]'
run "$d" set "on microsoft-edge-stable"
check "Edge on: flags file made with the switch, exit 0" \
    '[[ "$(cat "$(EF "$d")")" == "--enable-features=WebRtcPipeWireCamera" && "$(cat "$d/rc")" == 0 ]]'
check "Edge on: recorded (off, no file before)" '[[ "$(state_of "$d")" == "edge-flags off absent $(EF "$d")" ]]'
run "$d" status
check "status: Edge on" '[[ "$(field "$(line_of "$d" chrome "Microsoft Edge")" flag)" == on ]]'
run "$d" set "off microsoft-edge-stable"
check "Edge off: the file it made is gone" '[[ ! -e "$(EF "$d")" ]]'

# A flags file of the user's own: kept, and the feature joins their list.
d=$(new_env)
edge_launcher "$d" yes
mkdir -p "$d/home/.config"
printf -- '--ozone-platform=x11\n--enable-features=Foo,Bar\n' > "$(EF "$d")"
cp "$(EF "$d")" "$d/flags-before"
run "$d" set "on microsoft-edge-stable"
check "Edge on, own flags file: added to their --enable-features list (Chromium uses one), rest kept" \
    '[[ "$(cat "$(EF "$d")")" == "$(printf -- "--ozone-platform=x11\n--enable-features=Foo,Bar,WebRtcPipeWireCamera")" ]]'
run "$d" set "off microsoft-edge-stable"
check "Edge off, own flags file: just the feature taken out" 'cmp -s "$d/flags-before" "$(EF "$d")"'
run "$d" set "on microsoft-edge-stable"
run "$d" undo
check "--undo: their flags file as it was" 'cmp -s "$d/flags-before" "$(EF "$d")"'

# Microsoft's own package: no flags file, so a copy of its menu entry.
d=$(new_env)
edge_launcher "$d" no
mkdir -p "$d/share/applications"
printf '[Desktop Entry]\nName=Microsoft Edge\nExec=/usr/bin/microsoft-edge-stable %%U\n\n[Desktop Action new-window]\nExec=/usr/bin/microsoft-edge-stable --new-window\n' \
    > "$d/share/applications/microsoft-edge.desktop"
UD="$d/home/.local/share/applications/microsoft-edge.desktop"
run "$d" status
check "status: Edge via its menu entry, off" '[[ "$(field "$(line_of "$d" chrome "Microsoft Edge")" via)" == menu-entry && "$(field "$(line_of "$d" chrome "Microsoft Edge")" flag)" == off ]]'
run "$d" set "on microsoft-edge-stable"
check "Edge on: our copy of the menu entry, marked, switch after the program in every Exec line" \
    'grep -qx "X-PipeWire-Browser-Camera-Fix=true" "$UD" && grep -qx "Exec=/usr/bin/microsoft-edge-stable --enable-features=WebRtcPipeWireCamera %U" "$UD" && grep -qx "Exec=/usr/bin/microsoft-edge-stable --enable-features=WebRtcPipeWireCamera --new-window" "$UD"'
check "Edge on: the system entry untouched, the rest copied" \
    '! grep -q enable-features "$d/share/applications/microsoft-edge.desktop" && grep -qx "Name=Microsoft Edge" "$UD"'
run "$d" status
check "status: Edge on (menu entry)" '[[ "$(field "$(line_of "$d" chrome "Microsoft Edge")" flag)" == on ]]'
run "$d" set "off microsoft-edge-stable"
check "Edge off: our copy removed, the system's entry used again" '[[ ! -e "$UD" ]]'
run "$d" set "on microsoft-edge-stable"
run "$d" undo
check "--undo: our copy removed" '[[ ! -e "$UD" ]]'
printf '[Desktop Entry]\nExec=/opt/my-edge %%U\n' > "$UD"
run "$d" set "on microsoft-edge-stable"
check "a menu entry copy of the user's own: refused, untouched, exit 1" \
    '[[ "$(cat "$d/rc")" == 1 && "$(cat "$UD")" == "$(printf "[Desktop Entry]\nExec=/opt/my-edge %%U")" ]] && grep -q "your own copy" "$d/out"'
rm -f "$UD" "$d/share/applications/microsoft-edge.desktop"
run "$d" status
check "no flags file and no menu entry: flag=manual, via=none" \
    '[[ "$(field "$(line_of "$d" chrome "Microsoft Edge")" flag)" == manual && "$(field "$(line_of "$d" chrome "Microsoft Edge")" via)" == none ]]'
run "$d" set "on microsoft-edge-stable"
check "…and on is refused with the switch to use" '[[ "$(cat "$d/rc")" == 1 ]] && grep -q "Start it with --enable-features=WebRtcPipeWireCamera" "$d/out"'

# --yes adds Edge's switch like the other browsers' settings.
d=$(new_env)
edge_launcher "$d" yes
run "$d" yes
check "--yes: Edge's switch added, the check says so" \
    '[[ "$(cat "$(EF "$d")")" == "--enable-features=WebRtcPipeWireCamera" ]] && grep -q "Microsoft Edge:.*switch off" "$d/out"'

# Installed but never opened, GNOME Web, and portal IDs from what's installed.
d=$(new_env)
add_bin "$d" brave; add_bin "$d" vivaldi; add_bin "$d" epiphany
mkdir -p "$d/share/applications"; : > "$d/share/applications/org.gnome.Epiphany.desktop"
add_chrome "$d" .config/vivaldi '[]'
run "$d" status
check "status: Brave installed, never opened: chrome-unopened" 'grep -qxP "chrome-unopened\tlabel=Brave" "$d/out"'
check "status: Vivaldi has a profile: a normal line, not unopened" \
    '! grep -qP "chrome-unopened\tlabel=Vivaldi" "$d/out" && [[ -n "$(line_of "$d" chrome "label=Vivaldi")" ]]'
check "status: GNOME Web needs nothing: pipewire-native" 'grep -qxP "pipewire-native\tlabel=GNOME Web" "$d/out"'
check "portal IDs: Brave as org.chromium.Chromium, Vivaldi as com.vivaldi.Vivaldi (installed is enough)" \
    '[[ -n "$(line_of "$d" portal "id=org.chromium.Chromium")" && -n "$(line_of "$d" portal "id=com.vivaldi.Vivaldi")" ]]'
d2=$(new_env)
add_bin "$d2" epiphany
run "$d2" status
check "an epiphany command without GNOME Web's menu entry (Fedora's epiphany-runtime): not listed" \
    '! grep -q "^pipewire-native" "$d2/out"'
run "$d" check
check "check: never opened and GNOME Web said in words" \
    'grep -q "Brave: *installed, never opened" "$d/out" && grep -q "GNOME Web: *uses the camera through PipeWire by itself" "$d/out"'

# Edge's portal ID, and Firefox's own IDs (shown only when stored).
d=$(new_env)
edge_launcher "$d" no
run "$d" status
check "portal: Edge alone doesn't list org.chromium.Chromium (on GNOME it was stored under the empty ID)" '[[ -z "$(line_of "$d" portal "id=org.chromium.Chromium")" ]]'
check "portal: firefox not set: not listed (Firefox gets the dialog)" '! grep -qP "^portal\tid=firefox\t" "$d/out"'
add_bin "$d" google-chrome-stable
run "$d" yes
check "--yes never adds a \"yes\" for firefox" '[[ -z "$(perm_of "$d" firefox)" ]]'
store_set "$d" firefox yes
store_set "$d" org.mozilla.firefox no
run "$d" status
check "status: firefox and org.mozilla.firefox listed when stored" \
    'grep -qxP "portal\tid=firefox\tstate=yes" "$d/out" && grep -qxP "portal\tid=org.mozilla.firefox\tstate=no" "$d/out"'
run "$d" check
check "check: org.mozilla.firefox's \"no\" reported as refused" 'grep -q "org.mozilla.firefox: *no (refused without asking)" "$d/out"'
run "$d" set "allow org.mozilla.firefox"
check "allow over Flatpak Firefox's \"no\": yes, recorded" \
    '[[ "$(perm_of "$d" org.mozilla.firefox)" == yes ]] && grep -q "portal-was-no org.mozilla.firefox" <<< "$(state_of "$d")"'
d=$(new_env)
run "$d" set "allow firefox"
check "allow firefox with nothing refused: refused, nothing stored" \
    '[[ "$(cat "$d/rc")" == 1 && -z "$(perm_of "$d" firefox)" ]] && grep -q "firefox: nothing refused there to clear" "$d/out"'

# The options themselves.
for args in "--enable" "--status --check" "--yes --enable x" "--undo --status" "--allow" "--check --allow x"; do
    # shellcheck disable=SC2086  # the options are meant to split
    bash "$SCRIPT" $args &>/dev/null
    # shellcheck disable=SC2034  # read by check (eval)
    rc=$?
    check "\"$args\": refused with a usage message (exit 2)" '[[ $rc == 2 ]]'
done

# Enter alone: yes for the fixes the script is run for, no for removing a stored "no".
eval "$(extract_fn answer_yes)"
check "Enter means yes for the fixes" 'answer_yes yes ""'
check "Enter means no for a stored \"no\"" '! answer_yes no ""'
check "y and yes are yes, n is no" 'answer_yes no y && answer_yes no YES && ! answer_yes yes n && ! answer_yes yes maybe'
check "the fix questions show [Y/n], the stored-\"no\" one [y/N]" \
    '[[ "$(extract_fn ask)" == *"[Y/n]"* && "$(extract_fn ask_always)" == *"[y/N]"* ]]'

echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 ))
