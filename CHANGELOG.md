# Changelog

## Unreleased

- **Chrome flag set by the script itself**
  The Chrome / Chromium PipeWire camera flag is now read and set directly in each profile's `Local State` (native, snap and Flatpak Chrome, Chromium, Brave, Vivaldi, Opera), instead of through `chromium-pipewire-camera` from Andy's Camera Relay. That tool skipped the flag on Fedora without `libcamera-devel` and is gone once Camera Relay is uninstalled. The browser must be closed; a flag set to Disabled is only changed after asking, even with `--yes`; `--undo` puts each profile's own setting back. Changes recorded by older versions are still undone through `chromium-pipewire-camera`.
