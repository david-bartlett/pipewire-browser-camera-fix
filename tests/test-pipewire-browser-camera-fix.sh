#!/usr/bin/env bash
# Tests for pipewire-browser-camera-fix.sh.
#
# What matters, and is easy to break silently:
#   1. Portal app IDs are the ones the portal really uses (Chrome's own scope
#      ID per channel, snap.<name>) — a grant under any other ID does nothing.
#   2. A stored "no" is never changed without a person saying so, even --yes.
#   3. Firefox prefs are never edited while Firefox runs (it rewrites prefs.js
#      on exit), and only the profiles that need it are touched.
#   4. --undo puts back exactly what the script changed, and nothing else.
#   5. --check changes nothing.
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
# A fake home, a fake permission store behind a busctl stub ("ID PERM" lines),
# a fake chromium-pipewire-camera, and a PATH holding only the stubs plus the
# real tools the script uses — so this machine's own browsers can't leak in.
new_env() {
    local d="$TMP/env-$RANDOM$RANDOM" tool
    mkdir -p "$d/bin" "$d/home" "$d/proc" "$d/snap"
    : > "$d/store"
    for tool in grep sort head tail readlink mkdir rm rmdir cat sed wc mv cp mktemp chmod tr; do
        ln -s "$(command -v "$tool")" "$d/bin/$tool"
    done
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
        while read -r id perm; do out+=" \"\$id\" 1 \"\$perm\""; done < "\$store"
        echo "\$out y 0" ;;
    SetPermission)
        grep -v "^\$4 " "\$store" > "\$store.tmp"; mv "\$store.tmp" "\$store"
        echo "\$4 \$6" >> "\$store" ;;
    DeletePermission)
        grep -v "^\$3 " "\$store" > "\$store.tmp"; mv "\$store.tmp" "\$store" ;;
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
    disable) echo "  ✓ Google Chrome: PipeWire camera flag removed" ;;
esac
EOF
    chmod +x "$d/bin/busctl" "$d/bin/pgrep" "$d/bin/journalctl" "$d/flag-tool"
    echo "  Google Chrome:       ENABLED" > "$d/flag-status"
    printf '%s\n' "$d"
}

add_bin()   { printf '#!%s\n' "$BASH" > "$1/bin/$2"; chmod +x "$1/bin/$2"; }
add_snap()  { mkdir -p "$1/snap/$2/current"; }
store_set() { echo "$2 $3" >> "$1/store"; }
perm_of()   { awk -v id="$2" '$1 == id { print $2 }' "$1/store"; }
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
pref_in() { sed -n 's/^user_pref("media\.webrtc\.camera\.allow-pipewire", \(.*\));$/\1/p' "$1/home/$2/prefs.js"; }

# Run the script's checks (or --undo) in env $1 with mode $2, stdin not a terminal.
run() {
    local d="$1" mode="$2"
    (
        PATH="$d/bin"
        HOME="$d/home"
        unset XDG_STATE_HOME
        # shellcheck disable=SC2034  # read by the evaluated functions
        MODE="$mode"
        eval "$(sed -n '/^STATE_FILE=/,/^PORTAL_STORE_PATH=/p' "$SCRIPT")"
        for fn in section answer_yes ask ask_always record portal_store portal_camera_entries \
                  portal_camera_state running_chromium_scope_ids firefox_prefs_files \
                  firefox_pref_value firefox_running firefox_set_pref profile_label snap_profile \
                  check_environment check_chromium_flag check_firefox_pref check_portal \
                  undo_changes; do
            eval "$(extract_fn "$fn")"
        done
        eval "$(extract_fn browser_portal_app_ids | sed '1s/^browser_portal_app_ids()/real_ids()/')"
        browser_portal_app_ids() { real_ids "$d/proc" "$d/snap"; }
        chromium_flag_tool() { echo "$d/flag-tool"; }
        if [[ "$mode" == undo ]]; then
            undo_changes
        else
            check_environment; check_chromium_flag; check_firefox_pref; check_portal
        fi
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

# ── 4. Chrome flag ────────────────────────────────────────────────────────────
echo
echo "Chrome / Chromium flag"

d=$(new_env)
run "$d" yes
check "all ENABLED: enable not called" '! grep -qx enable "$d/flag-calls"'

d=$(new_env)
printf '  Google Chrome:       not set\n  Chromium:            ENABLED\n' > "$d/flag-status"
run "$d" yes
check "one not set: enable called" 'grep -qx enable "$d/flag-calls"'
check "chrome-flag recorded" 'grep -qx chrome-flag <<< "$(state_of "$d")"'

# ── 5. --check ────────────────────────────────────────────────────────────────
echo
echo "--check"

d=$(new_env)
add_bin "$d" google-chrome-stable
add_profile "$d" .mozilla/firefox/abc.default-release false
printf '  Google Chrome:       not set\n' > "$d/flag-status"
run "$d" check
check "no portal change" '! grep -q SetPermission "$d/calls" 2>/dev/null'
check "no Firefox change" '[[ "$(pref_in "$d" .mozilla/firefox/abc.default-release)" == false ]]'
check "no flag change" '! grep -qx enable "$d/flag-calls"'
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
printf '  Google Chrome:       not set\n' > "$d/flag-status"
run "$d" yes
# A "no" the script changed after asking, simulated in the state file.
store_set "$d" org.chromium.Chromium yes
echo "portal-was-no org.chromium.Chromium" >> "$d/home/.local/state/pipewire-browser-camera-fix/changes"
run "$d" undo
check "portal grants removed" '[[ -z "$(perm_of "$d" com.google.Chrome)$(perm_of "$d" snap.firefox)" ]]'
check "a \"no\" it changed is a \"no\" again" '[[ "$(perm_of "$d" org.chromium.Chromium)" == no ]]'
check "entry it never added kept" '[[ "$(perm_of "$d" org.mozilla.firefox)" == yes ]]'
check "Firefox pref back to false" '[[ "$(pref_in "$d" .mozilla/firefox/abc.default-release)" == false ]]'
check "snap profile still without the pref" '[[ -z "$(pref_in "$d" snap/firefox/common/.mozilla/firefox/def.default)" ]]'
check "Chrome flag disabled" 'grep -qx disable "$d/flag-calls"'
check "state file removed" '[[ -z "$(state_of "$d")" ]]'

d=$(new_env)
run "$d" undo
check "--undo with nothing recorded says so" 'grep -q "Nothing to undo" "$d/out"'

# Changes recorded before the rename live under browser-camera-fix/.
d=$(new_env)
store_set "$d" com.google.Chrome yes
mkdir -p "$d/home/.local/state/browser-camera-fix"
echo "portal com.google.Chrome" > "$d/home/.local/state/browser-camera-fix/changes"
run "$d" undo
check "--undo reads the pre-rename state file" '[[ -z "$(perm_of "$d" com.google.Chrome)" ]]'
check "pre-rename state file removed" '[[ ! -e "$d/home/.local/state/browser-camera-fix/changes" ]]'

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
