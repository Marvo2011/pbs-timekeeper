# Changelog

The release workflow takes the release notes from the section of the version in
`VERSION`, so every version needs one.

## 0.1.0

- First version.
- Menu bar app that backs up selected folders to a Proxmox Backup Server on a
  schedule (every hour by default), one pxar archive per folder in a snapshot
  of the group `host/<backup ID>`. Whole volumes are not backed up.
- Incremental backups with the metadata change detection: unchanged files are
  reused from the previous snapshot instead of being read again.
- Old snapshots are pruned after each backup: 24 hourly, 30 daily and 52
  weekly by default.
- Browser with a timeline of all snapshots. It mounts the archives read-only
  with FUSE-T, keeps the folder shown while moving through time, and restores
  files and folders to their original place or a chosen folder. Restoring
  copies from the mount, so only the selected files are read from the server
  (extended attributes and file flags are not restored).
- While a backup runs, the menu bar icon turns and the menu shows the elapsed
  time and how much was read and uploaded.
- Password and encryption key password are stored in the Keychain.
- Failed backups are retried after 15 minutes, then 30, 60, … up to 4 hours.
- Quitting the app stops a running backup, and a client left behind by a
  killed app is stopped at the next launch. Before, it kept the backup group
  locked on the server (`unable to acquire backup group lock`).
- Shows in the menu and settings whether the app has Full Disk Access, and how
  many items a backup skipped because macOS denied access.
- Bundles proxmox-backup-client 4.2.10+20261120 of the macOS port.
