# aojm

Stands for "Anya's Online Judge Mini". A quick and easy to use CLI tool to record your desktop and acitvity logs for competitive programming contests. Only supports linux systems as of June 2026.

After downloading the .sh script, nstall with:

```bash
chmod +x aojm.sh
sudo install -m 755 aojm.sh /usr/local/bin/aojm
```

## Usage

- `aojm init`: Initialize configuration and detect hardware (webcam, encoder, etc.).
- `aojm start <contest_url>`: Open the contest URL and start recording (screen, webcam, audio, window logs).
- `aojm stop`: Stop the current recording session.
- `aojm status`: View the status of active and recent sessions.
- `aojm preview`: Preview the current or latest video recording.
- `aojm upload [recent|all]`: Upload completed recordings to remote storage via rclone.
- `aojm clean [keep_count] [--yes] | --empty-trash`: Move old sessions to trash or empty the trash.
- `aojm settings [list | set <key> <value>]`: View or modify configuration settings.
