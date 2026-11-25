# Changelog

## Unreleased

- **Snap Chromium is found**
  Snap Chromium keeps its settings in `~/snap/chromium/common/chromium`, which the script didn't look in, so it showed as a plain "Chromium" that had never been opened, and its flag couldn't be set. It's now found there and labelled "Chromium (snap)", also when it's installed but not opened yet. Found on Ubuntu 26.10.
- **Snap Firefox "can" crash on the PipeWire camera**
  The messages said it does. Firefox 161.0-1 on Ubuntu 26.10 worked with the pref on, so they now say it can. The script still keeps the pref off there, because the V4L2 camera works in every version.

- **Edge: turning it on puts back a lost switch**
  If the copy of Edge's menu entry this script made had lost its PipeWire camera switch (an edit, say), `--status` rightly said off, but `--enable` said "already on" just because the copy was there, and left it off. Now it puts the switch back. Found by Codex review 10 of galaxybook-intel-camera.
- **Flatpak Chrome-family browsers: a stored "no" is shown**
  A Flatpak Chrome (or Chromium, Brave, Edge, Vivaldi, Opera) uses its Flatpak ID with the portal. Without the same browser installed natively or running, a "no" stored for it wasn't listed, so nothing showed why the camera was refused, and `--allow` turned the ID down. Now an installed Flatpak browser's ID is shown when something is stored for it, and `--allow` clears a "no" there. "Not set" stays hidden, because GNOME's dialog works for Flatpaks. Found by Codex review 10 of galaxybook-intel-camera.

- **`--status` lists only browsers that are installed**
  Uninstalling a Chrome-family browser leaves its settings folder behind, and `--status` still listed it (Chromium on Fedora, so a settings window showed a row for a browser that was gone). A profile now counts only while its browser's command is on PATH, or its snap or Flatpak is installed. The interactive check still names every profile it finds.

- **GNOME Web found by its menu entry**
  It was listed whenever an `epiphany` command existed, but Fedora's `epiphany-runtime` package has one without the browser. Now it's found by GNOME Web's menu entry, `org.gnome.Epiphany.desktop` (native, or a Flatpak's).

- **Firefox's portal IDs**
  On GNOME the portal stores a normal Firefox as `firefox`, and Flatpak Firefox as `org.mozilla.firefox`. Like the empty ID, they're now shown when something is stored, and a "no" there is offered for removal (always asking) and cleared by `--allow`. A "yes" is never added for them by itself: Firefox gets the portal's dialog.

- **Microsoft Edge**
  Edge has no PipeWire camera entry in `edge://flags`, but starting it with `--enable-features=WebRtcPipeWireCamera` works. The script now adds that switch: to `~/.config/microsoft-edge-stable-flags.conf` where Edge's launcher reads it (the AUR package), or to a copy of Edge's menu entry in `~/.local/share/applications/` (Microsoft's own packages). An `--enable-features=` you already have gets the feature added to it. `--status` lists Edge, `--enable`/`--disable microsoft-edge-stable` turn it on and off, and `--undo` takes it out.

- **Browsers never opened, GNOME Web, and more portal IDs**
  A Chrome-family browser that's installed but has never been opened is now named (it has no settings yet), like Firefox. GNOME Web is listed as needing nothing. Brave and Opera use Chromium's portal ID, `org.chromium.Chromium`, and Vivaldi `com.vivaldi.Vivaldi`, so they're covered on GNOME when installed, not only while running.

- **`--allow`, and apps without an app ID**
  `--allow ID` stores the portal camera permission for one browser, for a settings window's Allow button: for a stored "no", or "not set" on GNOME, where the dialog can't appear. It's recorded, so `--undo` puts back what was there.
  The portal stores some apps under an empty ID: those it can't name, such as Firefox on LXQt, which doesn't start apps in their own systemd unit. That entry is now shown as `(no app ID)` (in `--status` as `id=` with nothing after it), and a "no" stored there is offered for removal, always asking first, like other stored "no"s. A "yes" is never added there by itself, as it covers every unnamed app. `--allow ''` clears a "no" there.

- **`--status`, `--enable` and `--disable`, for a settings window**
  `--status` prints the checks as tab-separated lines another program can read, and changes nothing. `--enable TARGET` and `--disable TARGET` change one browser profile: on, or back to the browser's own default (snap Firefox: off). They refuse, with the reason, while that browser runs, and exit 1 if a target wasn't changed. The changes are recorded, so `--undo` still puts back how things were before the first one. Made for galaxybook-intel-camera's tray, so a browser can be fixed after the install (once Chrome is closed, or Firefox has been opened once).
  `--undo` now also puts a Chrome flag back to Enabled when `--disable` turned off one you had enabled yourself.

- **Firefox never opened: says what to do**
  On a new install Firefox has no profile until it's first started. Instead of "No Firefox profile found.", the script now says Firefox hasn't been opened yet: open it once, close it, and run the script again. "No Firefox profile found." is kept for when Firefox isn't installed.

- **"Still no camera?" also points to `galaxybook-camera doctor`**
  The last hint looked only for Andy's `camera-relay`. With galaxybook-intel-camera's relay installed, it now suggests `galaxybook-camera doctor`.

- **Firefox's prefs.js is never replaced by a part-written copy**
  On a full disk, changing the PipeWire pref (or `--undo` putting it back) could replace `prefs.js` with the part that had been written, and say nothing. Every step is now checked, and the new copy is flushed to disk before it replaces the original. If anything fails, `prefs.js` stays as it was, the change is reported, and `--undo` keeps it for the next run. The one-time backup is made the same way.

- **`--undo` retries what it couldn't put back**
  Before, `--undo` only kept a change it had skipped because a browser was running. If the portal didn't answer, or a write failed, the change was dropped from the list without being undone, and `--undo` still reported success. Now every change it can't put back stays recorded and is listed, `--undo` exits 1, and running it again retries just those. A change is dropped once it's undone, or when there's nothing left to undo (the profile is gone, or you changed the setting yourself since).
  Running the script again no longer adds a second record for a profile or browser ID, so `--undo` puts back the state from before the first run, not an in-between one.

- **Chrome flag set by the script itself**
  The Chrome / Chromium PipeWire camera flag is now read and set directly in each profile's `Local State` (native, snap and Flatpak Chrome, Chromium, Brave, Vivaldi, Opera), instead of through `chromium-pipewire-camera` from Andy's Camera Relay. That tool skipped the flag on Fedora without `libcamera-devel` and is gone once Camera Relay is uninstalled. The browser must be closed; a flag set to Disabled is only changed after asking, even with `--yes`; `--undo` puts each profile's own setting back. Changes recorded by older versions are still undone through `chromium-pipewire-camera`.
