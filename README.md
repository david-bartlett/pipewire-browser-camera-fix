# Pipewire Browser Camera Fix

A script to run when the webcam works in other apps but not in **Chrome, Chromium or Firefox**: no camera listed, or the page stuck at **"Waiting for your permission"** with no prompt.

It checks the three things those browsers need on the PipeWire camera path, shows what it found, and asks before changing anything:

| Check | What it looks at | Fix |
|---|---|---|
| Chrome / Chromium flag | `chrome://flags/#enable-webrtc-pipewire-camera` in each profile | Turns it on, using `chromium-pipewire-camera` from camera-relay |
| Firefox pref | `media.webrtc.camera.allow-pipewire` in each profile's `prefs.js` (native, snap, Flatpak) | Turns it on for normal and Flatpak Firefox, and **off for snap Firefox**, which crashes on the PipeWire camera ([below](#snap-firefox)). Firefox must be closed; it keeps a backup of `prefs.js` |
| Portal camera permission | The xdg-desktop-portal permission store, for the browsers GNOME can't show the camera dialog for | Allows those browsers to use the camera without the dialog. The browser still asks you per site |

Everything it changes is recorded, and `--undo` puts it back.

## Usage

Run it as yourself, not with `sudo`:

```bash
./browser-camera-fix.sh            # check, then ask before each change
./browser-camera-fix.sh --check    # check only, change nothing
./browser-camera-fix.sh --yes      # make the changes without asking
./browser-camera-fix.sh --undo     # put back what it changed
```

Then quit each browser completely and reopen it **from the app menu, not a terminal**. If there's still no camera, run `camera-relay doctor`.

It needs `busctl`, which comes with systemd. For the Chrome flag it uses `chromium-pipewire-camera`, which `webcam-fix-book5` and `webcam-fix-libcamera` install. Without it, the script tells you to set the flag by hand.

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

Nothing outside the snap can fix that, so the script leaves the pref off there (and turns it off if it's on). Snap Firefox then uses the V4L2 camera, which Camera Relay's loopback device provides. Ubuntu tracks snap Firefox and PipeWire cameras as [LP#2136591](https://bugs.launchpad.net/bugs/2136591). Normal and Flatpak Firefox aren't affected.

## What it changes

- **Portal:** a "yes" for each browser ID you agree to, stored in the portal's permission store (`devices` / `camera`).
- **Firefox:** the `media.webrtc.camera.allow-pipewire` line in `prefs.js` (on, or off in snap Firefox). The first time it edits a profile it saves `prefs.js.browser-camera-fix.bak` next to it.
- **Chrome / Chromium:** the PipeWire camera flag, through `chromium-pipewire-camera`.

The list of changes is kept in `~/.local/state/browser-camera-fix/changes`. `--undo` reads it:
- it removes the portal permissions it added;
- it puts a "no" it changed back to "no";
- it restores each Firefox pref to its previous value;
- it turns the Chrome flag off again if the script was what turned it on.

## Tests

```bash
./tests/test-browser-camera-fix.sh
```

These need no browser, portal or session bus. They cover the app IDs, stored decisions, Firefox profiles (including Firefox running), the Chrome flag, `--check` and `--undo`.
