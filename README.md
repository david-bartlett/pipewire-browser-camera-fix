# PipeWire Browser Camera Fix

A script to run when the webcam works in other apps but not in **Chrome, Chromium or Firefox**: no camera listed, or the page stuck at **"Waiting for your permission"** with no prompt.

It checks the three things those browsers need on the PipeWire camera path, shows what it found, and asks before changing anything:

| Check | What it looks at | Fix |
|---|---|---|
| Chrome / Chromium flag | `chrome://flags/#enable-webrtc-pipewire-camera` in each profile | Turns it on in Chrome, Chromium, Brave, Vivaldi and Opera (native, snap, Flatpak). The browser must be closed; it keeps a backup of `Local State`. A flag you set to Disabled is only changed if you say yes ([below](#the-chrome-flag)) |
| Firefox pref | `media.webrtc.camera.allow-pipewire` in each profile's `prefs.js` (native, snap, Flatpak) | Turns it on for normal and Flatpak Firefox, and **off for snap Firefox**, which crashes on the PipeWire camera ([below](#snap-firefox)). Firefox must be closed; it keeps a backup of `prefs.js`. Only the profiles Firefox actually uses are changed ([below](#which-firefox-profiles)) |
| Portal camera permission | The xdg-desktop-portal permission store, for the browsers GNOME can't show the camera dialog for | Allows those browsers to use the camera without the dialog. The browser still asks you per site |

Everything it changes is recorded, and `--undo` puts it back.

## Who it's for

Anyone whose browser gets the webcam through PipeWire and xdg-desktop-portal. That's the usual route for laptop cameras run by libcamera (Intel IPU6 and IPU7), and for any webcam once a browser's PipeWire camera option is on.

It started as a companion to Andy's [Samsung Galaxy Book Linux fixes](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes), whose `webcam-fix-book5` and `webcam-fix-libcamera` set up the camera and Camera Relay. It doesn't need them, and works the same with or without them.

## Get it

```bash
git clone https://github.com/david-bartlett/pipewire-browser-camera-fix.git
cd pipewire-browser-camera-fix
```

## Usage

Run it as yourself, not with `sudo`:

```bash
./pipewire-browser-camera-fix.sh            # check, then ask before each change
./pipewire-browser-camera-fix.sh --check    # check only, change nothing
./pipewire-browser-camera-fix.sh --yes      # make the changes without asking
./pipewire-browser-camera-fix.sh --undo     # put back what it changed
```

Then quit each browser completely and reopen it **from the app menu, not a terminal**. If there's still no camera, run `camera-relay doctor` (Andy's fixes) or `galaxybook-camera doctor` (galaxybook-intel-camera).

**Firefox never opened yet?** On a new install Firefox has no profile until it's first started, so there's nothing to change. The script says so: open Firefox once, close it, and run the script again.

It needs `busctl`, which comes with systemd.

### For other programs: `--status`, `--enable`, `--disable`

A settings window can show the same checks and change one browser at a time:

```bash
./pipewire-browser-camera-fix.sh --status                       # the checks as tab-separated lines; changes nothing
./pipewire-browser-camera-fix.sh --enable  ~/.config/google-chrome
./pipewire-browser-camera-fix.sh --disable ~/.mozilla/firefox/abc.default-release/prefs.js
```

`--status` prints one line per thing found, `KIND` then `key=value` fields, separated by tabs, for example:

```
chrome	label=Google Chrome	target=/home/me/.config/google-chrome	flag=off	running=yes
firefox	label=Firefox	target=/home/me/.mozilla/firefox/abc.default-release/prefs.js	pref=off	from=default	distro=none	kind=native	profile=abc.default-release	default=yes	running=no
portal	id=com.google.Chrome	state=yes
```

The kinds are `chrome`, `firefox`, `firefox-none` (with `installed=yes` when Firefox is there but has never been opened), `firefox-unused`, `portal`, `chrome-none`, `portal-none`, `portal-unreachable` and `no-python`. The comment above `status_report` in the script lists every field. Ignore fields you don't know: more may be added.

`--enable` and `--disable` take a `target` from `--status`: a Chrome-family profile folder, or a Firefox `prefs.js`. Only profiles the script finds itself are changed. `--enable` turns the flag or pref on; `--disable` puts it back to the browser's own default (snap Firefox: off). They refuse, with the reason, while that browser runs, for snap Firefox (`--enable`) and where a `user.js` decides, and exit 1 if any target wasn't changed. Each change is recorded like any other, so `--undo` still goes back to how things were before the first change.

### The Chrome flag

Chrome keeps its flags in each profile's `Local State` file, which it rewrites when it quits. So the script changes the flag only while that browser is closed (it checks the profile's lock, and asks `flatpak` for Flatpak browsers), keeps a backup (`Local State.pipewire-browser-camera-fix.bak`), and touches nothing else in the file.

- **Not set:** turned on (Enter or `--yes`).
- **Disabled:** someone may have chosen that, so it always asks first, even with `--yes`.
- **`--undo`:** puts each profile back to what it was before: Default, or Disabled.

It needs `python3` to edit the file. Without it, it tells you to set the flag by hand: open `chrome://flags/#enable-webrtc-pipewire-camera`, set it to **Enabled**, then fully quit and reopen Chrome.

Versions before November 2026 changed the flag through `chromium-pipewire-camera` from Andy's Camera Relay. That tool skips the flag when it can't find libcamera's development files (on Fedora without `libcamera-devel`, for example) and isn't there at all once Camera Relay is uninstalled. `--undo` still hands changes those versions made back to it.

## Why "Waiting for your permission"

On GNOME, Chrome and snap browsers (such as Ubuntu's Firefox) can wait forever with no prompt, and the user journal shows:

```
xdg-desktop-portal: A backend call failed: ... AccessDenied: Only the focused app is allowed to show a system access dialog
```

The script reports how many times this has happened since boot.

<details>
<summary>What's going on</summary>

On the PipeWire camera path, the browser asks xdg-desktop-portal for the camera before it shows its own prompt. With no decision stored, the portal asks GNOME Shell to show an "allow camera?" dialog. GNOME Shell shows it only if the requesting app ID, plus `.desktop`, is the focused window's app. For these browsers the two never match:

| Browser | App ID the portal uses | Window's app in GNOME |
|---|---|---|
| Google Chrome (native) | `com.google.Chrome`, from the systemd scope Chrome creates for itself (`app-com.google.Chrome-<pid>.scope`) | `google-chrome.desktop` |
| Chrome Beta / Unstable / Canary | `com.google.Chrome.beta` / `.unstable` / `.canary` | `google-chrome-beta.desktop`, … |
| Chromium (native) | `org.chromium.Chromium` | `chromium.desktop` or `chromium-browser.desktop` |
| Snap browsers | `snap.<name>`, e.g. `snap.firefox` | `<name>_<app>.desktop`, e.g. `firefox_firefox.desktop` |

GNOME refuses the dialog, the portal stores nothing, and every attempt hangs the same way. PipeWire and libcamera versions play no part. KDE Plasma doesn't have this check: on Debian 13 KDE, Chrome and Firefox work with nothing changed.

Where the IDs come from:

- Chromium's `base/version_info/nix/version_extra_utils.cc` (`GetAppName`) and `components/dbus/xdg/systemd.cc`, which creates the scope except under Flatpak or Snap;
- xdg-desktop-portal's `shared/xdp-app-info-snap.c` for snaps, and `shared/xdp-app-info-host.c`, which reads a normal app's ID from its systemd unit;
- GNOME Shell's `js/ui/accessDialog.js` for the focus check.

Storing "yes" for the app ID means the portal doesn't need the dialog. The script also finds other Chromium-based browsers (Brave, Edge, Vivaldi, Opera) if they're running when you run it, from the scope they create for themselves.

**Firefox installed as a normal package or Flatpak** isn't affected when it's started from the app menu, because its ID matches its window. **Started from a terminal**, it takes on the terminal's ID and GNOME refuses the dialog. No stored permission can fix that, so start it from the app menu.

A stored **"no"** blocks the camera without asking. It may be your own choice, or a stale denial left by a portal crash ([Andycodeman#37](https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/37)). The script never changes one without asking you, even with `--yes`.

</details>

## Snap Firefox

Ubuntu's snap Firefox crashes when a site asks for the camera with the PipeWire pref on. Inside the snap, its PipeWire library can't load PipeWire's own plugins, so it can't even start; the log just before the crash shows:

```
[E] pw.loop [loop.c:67 pw_loop_new()] …: can't make support.system handle: No such file or directory
```

Nothing outside the snap can fix that, so the script leaves the pref off there (and turns it off if it's on). Snap Firefox then opens the camera directly as a V4L2 device: a USB webcam, or Camera Relay's loopback device for a libcamera laptop camera. Ubuntu tracks snap Firefox and PipeWire cameras as [LP#2136591](https://bugs.launchpad.net/bugs/2136591). Normal and Flatpak Firefox aren't affected.

## Which Firefox profiles

The script shows Firefox the same way as Chrome, `Firefox: ENABLED` or `DISABLED`, with `Firefox (snap)` and `Firefox (flatpak)` for those. When one kind of Firefox has several profiles in use, each is named, and the one Firefox opens by default is marked (from `installs.ini`, or `profiles.ini` on older setups). It leaves some profiles alone:

- **Profiles Firefox doesn't use.** Since Firefox 147, new profiles go in `~/.config/mozilla/firefox`, but only when `~/.mozilla` doesn't exist. While it does, Firefox keeps using `~/.mozilla/firefox` and never reads `~/.config/mozilla`. Profiles there aren't listed or changed; the script just says how many it skipped. Flatpak Firefox works the same way inside `~/.var/app/org.mozilla.firefox`.
- **Profiles that are already on through the package's own default.** Fedora's Firefox package turns the pref on in `firefox-redhat-default-prefs.js`, so a profile without the line is already on. The script reads the defaults a native Firefox package ships, so such a profile shows as `ENABLED` and isn't changed.
- **Profiles with a `user.js` that sets the pref.** Firefox applies `user.js` at every start, over `prefs.js`, so the script says so and leaves that line for you to change.

## What it changes

- **Portal:** a "yes" for each browser ID you agree to, stored in the portal's permission store (`devices` / `camera`).
- **Firefox:** the `media.webrtc.camera.allow-pipewire` line in `prefs.js` (on, or off in snap Firefox). The first time it edits a profile it saves `prefs.js.pipewire-browser-camera-fix.bak` next to it. `prefs.js` is only replaced by a copy that was written in full, so a full disk leaves it as it was.
- **Chrome / Chromium:** the PipeWire camera flag in each profile's `Local State`. The first time it edits a profile it saves `Local State.pipewire-browser-camera-fix.bak` next to it.

The list of changes is kept in `~/.local/state/pipewire-browser-camera-fix/changes`. `--undo` reads it:
- it removes the portal permissions it added;
- it puts a "no" it changed back to "no";
- it restores each Firefox pref to its previous value;
- it puts each Chrome profile's flag back to what it was (Default, Enabled or Disabled) where the script changed it, and removes the backup.

Only the first change to each profile or browser ID is recorded, so running the script again later (after you changed something back, say) doesn't replace what it was before the first run.

Anything `--undo` can't put back stays in the list, and it tells you which and exits with an error. That might be a browser that's running, the portal not answering, or a file it couldn't write. Close that browser, or fix what it says, and run `--undo` again: it retries just those. Something you've changed yourself since isn't put back; it's left as it is and dropped from the list.

Changes made before the project was renamed are in `~/.local/state/browser-camera-fix/changes`; `--undo` reads that too.

## Where it's been checked

- **CachyOS (GNOME, Chrome 157):** the "Waiting for your permission" hang, and storing the portal permission fixes it.
- **Ubuntu 26.04 (GNOME):** the same hang with Chrome, and the script fixes it. Snap Firefox crashes with the PipeWire pref on, so the script keeps it off there. With Mozilla's deb Firefox ([packages.mozilla.org](https://packages.mozilla.org/apt)) instead of the snap, the camera works with the pref on.
- **Debian 13 (KDE):** Chrome and Firefox work with nothing changed.
- **EndeavourOS (GNOME):** the script fixes it; the camera then works in Chrome and Firefox.
- **Fedora 45 (KDE):** the Firefox check, with an unused profile in `~/.config/mozilla` (skipped) and Fedora's package default turning the pref on.

## Tests

```bash
./tests/test-pipewire-browser-camera-fix.sh
```

These need no browser, portal or session bus. They cover the app IDs, stored decisions, Firefox profiles (including Firefox running, profiles Firefox doesn't use, package defaults and `user.js`), the Chrome flag, `--check` and `--undo` (including what it keeps when something can't be put back), and `--status`, `--enable` and `--disable`.
