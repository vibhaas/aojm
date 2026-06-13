# aojm (Anya's Online Judge Mini)

A lightweight CLI tool to record desktop, webcam, and activity logs for competitive programming contests on Linux.

## Installation

```bash
chmod +x aojm.sh
sudo install -m 755 aojm.sh /usr/local/bin/aojm
```

## Commands

- `aojm init`: Initializes configuration and detect hardware (webcam/audio).
- `aojm help`: Shows commands.
- `aojm start <name_or_url>`: Start recording the screen and webcam in the background.
- `aojm stop`: Finalize and safely stop the current recording session.
- `aojm status`: Display a table of all recent and active sessions.
- `aojm preview`: Preview the current or latest video recording. (Warning: doesn't work on Wayland)
- `aojm upload [recent|all]`: Upload recordings to Google Drive and generate a public sharing link.
- `aojm clean [count]`: Safely trash old, successfully uploaded sessions.
- `aojm force-delete [count]`: Trash un-uploaded sessions, bypassing safety locks.
- `aojm settings`: View or modify configuration variables.
- `aojm show`: Open the local recordings folder (`~/.aojm/sessions`) in your GUI file manager.
- `aojm update`: Pull the latest script updates directly from GitHub.

## Under the Hood (Features)

- **Native Wayland & X11 Capture**: 
  - On **Wayland**, `aojm` bypasses restrictive XDG portal bugs by natively bridging with the `org.gnome.Shell.Screencast` DBus interface. It securely captures the screen to a raw MP4 and automatically downscales it post-recording using `ffmpeg` to save disk space.
  - On **X11**, it leverages `x11grab` for hardware-accelerated capture and supports live active-window-title logging via `xdotool`. (Note: Not yet tested!)
- **Smart Rclone Cloud Sync**:
  - Checks if there is enough Google Drive storage space before attempting an upload.
  - Uses `rclone link` to generate and print a public sharing URL.
- **Fail-Safe Data Retention**:
  - The `clean` command strictly prevents the deletion of any recording that has not yet been verified as `UPLOADED=1`.
  - There is a `force-delete` command, otherwise.
- **Updates**: 
  - The `update` command queries the GitHub repo and patches the binary in `/usr/local/bin`.