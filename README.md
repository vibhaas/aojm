# aojm

Stands for "Anya's Online Judge Mini". A quick and easy to use CLI tool to record your desktop and acitvity logs for competitive programming contests. Only supports linux systems as of June 2026.

After downloading the .sh script, install with:

```bash
chmod +x aojm.sh
sudo install -m 755 aojm.sh /usr/local/bin/aojm
```

## Usage

- `aojm init`: Initialize configuration, detect hardware, and get guidance for setting up Google Drive uploads.
- `aojm start <contest_name_or_url>`: Start recording (screen, webcam, audio, window logs).
- `aojm stop`: Stop the current recording session.
- `aojm status`: View the status and combined sizes of active and recent sessions.
- `aojm preview`: Preview the current or latest video recording (automatically manages Wayland streams).
- `aojm upload [recent|all]`: Safely upload completed recordings to Google Drive (verifies available space first).
- `aojm clean [keep_count] [--yes] | --empty-trash`: Move old sessions to trash or empty the trash.
- `aojm settings [list | set <key> <value>]`: View or modify configuration settings.
- `aojm show`: Open the local recordings folder (`~/.aojm/sessions`) in your file manager.
- `aojm update`: Check GitHub for updates and safely patch the local installation.
- `aojm help`: Display the help menu with detailed command descriptions.

## Features

- **X11 & Wayland Support**: Automatically adapts to your desktop environment. On Wayland, it natively splits screen and webcam recording and prompts you to share your screen securely.
- **Smart Cloud Uploads**: Seamlessly uploads your sessions to Google Drive via `rclone`, complete with pre-upload storage space checks to ensure successful syncing.
- **Auto-Updates**: Built-in update mechanism to easily fetch and apply the latest script version directly from GitHub.