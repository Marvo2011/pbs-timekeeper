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
  files and folders to their original place or a chosen folder.
- Password and encryption key password are stored in the Keychain.
- Bundles proxmox-backup-client 4.2.10+20261119 of the macOS port.
