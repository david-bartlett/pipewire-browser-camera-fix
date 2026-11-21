# Changelog

## Unreleased

- **`--undo` retries what it couldn't put back**
  Before, `--undo` only kept a change it had skipped because a browser was running. If the portal didn't answer, or a write failed, the change was dropped from the list without being undone, and `--undo` still reported success. Now every change it can't put back stays recorded and is listed, `--undo` exits 1, and running it again retries just those. A change is dropped once it's undone, or when there's nothing left to undo (the profile is gone, or you changed the setting yourself since).
  Running the script again no longer adds a second record for a profile or browser ID, so `--undo` puts back the state from before the first run, not an in-between one.

- **Chrome flag set by the script itself**
  The Chrome / Chromium PipeWire camera flag is now read and set directly in each profile's `Local State` (native, snap and Flatpak Chrome, Chromium, Brave, Vivaldi, Opera), instead of through `chromium-pipewire-camera` from Andy's Camera Relay. That tool skipped the flag on Fedora without `libcamera-devel` and is gone once Camera Relay is uninstalled. The browser must be closed; a flag set to Disabled is only changed after asking, even with `--yes`; `--undo` puts each profile's own setting back. Changes recorded by older versions are still undone through `chromium-pipewire-camera`.
