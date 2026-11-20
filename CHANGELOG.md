# Changelog

The release workflow takes the release notes from the section of the version in
`VERSION`, so every version needs one.

## 0.1.0

- First version.
- Menu bar app that backs up selected folders to a Proxmox Backup Server on a
  schedule (every hour by default), one pxar archive per folder in a snapshot
  of the group `host/<backup ID>`. Whole volumes are not backed up.
- Incremental backups with the metadata change detection: unchanged files are
  reused from the previous snapshot instead of being read again. The legacy
  mode (one .pxar per folder, all files read on every backup) can be chosen in
  Settings → General, which also explains both modes.
- Old snapshots are pruned after each backup: 24 hourly, 30 daily and 52
  weekly by default.
- Browser with a timeline of all snapshots. It mounts the archives read-only
  with FUSE-T, keeps the folder shown while moving through time, and restores
  files and folders to their original place or a chosen folder. Restoring
  copies from the mount, so only the selected files are read from the server
  (extended attributes and file flags are not restored).
- While a backup runs, the menu bar icon turns and the menu shows the elapsed
  time and how much was read and uploaded. The browser shows it as "Now" on top
  of the timeline, with the folder being read and a stop button, and moves to
  the new snapshot when it is finished.
- Single backups can be removed from the server in the browser (trash button,
  context menu or ⌫ on the timeline), after a confirmation. Protected
  snapshots cannot be removed, and nothing is removed while a backup runs.
- Encryption key creation in Settings → Server, as in Proxmox VE: the key is
  created without a password, and the paper key (key as text and QR code) can
  be printed and the key file saved elsewhere. A new key has to be confirmed
  as stored safely. An existing key is moved aside, never overwritten.
- Settings → About and "About PBS Timekeeper" in the menu show the version of
  the app and of the proxmox-backup-client in use (bundled or configured).
- Password and encryption key password are stored in the Keychain.
- Failed backups are retried after 15 minutes, then 30, 60, … up to 4 hours.
- Quitting the app stops a running backup, and a client left behind by a
  killed app is stopped at the next launch. Before, it kept the backup group
  locked on the server (`unable to acquire backup group lock`).
- Shows in the menu and settings whether the app has Full Disk Access, and how
  many items a backup skipped because macOS denied access.
- Bundles proxmox-backup-client 4.2.10+20261120 of the macOS port.
