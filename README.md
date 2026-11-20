# PBS Timekeeper

Automatic, hourly backups of your Mac's folders to a
[Proxmox Backup Server](https://www.proxmox.com/en/proxmox-backup-server), with a
timeline to browse and restore older versions.

PBS Timekeeper is a menu bar app around `proxmox-backup-client` from the
[macOS port](https://github.com/Marvo2011/proxmox-backup-client-mac), which is
bundled. It backs up **folders only**: pick the folders you care about (e.g.
your home folder or Documents and Projects), whole disks and the macOS system
are not backed up.

This is an unofficial project, not affiliated with Proxmox Server Solutions GmbH
or Apple Inc.

## Features

- **Scheduled backups** every hour (or 2, 4, 6, 12, 24 hours), also on demand
  from the menu bar. Missed backups run after waking up, failed ones are
  retried after 15 minutes.
- **Incremental**: every backup is a full snapshot on the server, but only
  changed files are read (metadata change detection) and only new data is
  uploaded (deduplication). The legacy mode, which reads all files on every
  backup and stores one `.pxar` per folder, is available in the settings.
- **Retention like you know it**: hourly snapshots for a day, daily ones for a
  month, weekly ones for a year (configurable). Older snapshots are pruned after
  each backup, the space is freed by the garbage collection on the server.
- **Timeline browser**: all snapshots by date on the right, the files of the
  selected one on the left. The folder shown stays the same while you step
  through time (⌘↑ / ⌘↓), so finding the version before an accident is quick.
- **Restore** files and folders to where they were (keep both or replace, the
  replaced items go to the Trash) or to another folder. They are copied from
  the mounted snapshot, which reads only the selected files from the server.
  Permissions and dates are kept, extended attributes and file flags are not
  (FUSE-T does not show them), use `proxmox-backup-client restore` for those.
- Optional client-side **encryption**: create a key in the settings and print
  its paper key (text and QR code), or use an existing key file. Keep a copy of
  the key outside the Mac: without it, encrypted backups cannot be restored.
- Passwords are stored in the **Keychain**.

## Requirements

- macOS 14 or newer on Apple Silicon.
- A Proxmox Backup Server and a user or API token with the `DatastorePowerUser`
  role on the datastore (or namespace): it can back up and prune its own
  backups. With `DatastoreBackup` only, set all retention values to 0 and prune
  on the server instead.
- [FUSE-T](https://www.fuse-t.org) for browsing backups
  (`brew install --cask macos-fuse-t/cask/fuse-t`). Backing up works without it.

## Installation

Download the zip of the latest
[release](https://github.com/Marvo2011/pbs-timekeeper/releases), unpack it and
move `PBS Timekeeper.app` to `/Applications`. The app is not notarized, remove
the quarantine attribute before the first start:

```sh
xattr -dr com.apple.quarantine "/Applications/PBS Timekeeper.app"
```

## Setup

1. Open **Settings…** from the menu bar icon.
2. **Server**: address, datastore, optionally a namespace, user or API token
   (`user@pbs!token`) and password or token secret. For a self-signed
   certificate, enter its fingerprint (shown on the server's dashboard under
   *Show Fingerprint*). *Test Connection* checks the settings.
3. **Folders**: add the folders to back up. Each folder becomes an archive in
   the snapshot. Folders inside each other and whole volumes are refused.
   Exclude patterns apply to all folders (`node_modules`, `*.tmp`, …).
4. **General**: grant *Full Disk Access* (needed for Desktop, Documents,
   Downloads, Mail and other protected folders) and enable *Open at login*.

The backups of this Mac are stored as `host/<backup ID>` (the host name by
default), so they can also be used with `proxmox-backup-client` directly or in
the PBS web interface.

## Files

| What | Where |
|------|-------|
| Settings | `~/Library/Application Support/PBSTimekeeper/config.json` |
| State of the last backup | `~/Library/Application Support/PBSTimekeeper/state.json` |
| Logs of backups and restores | `~/Library/Logs/PBSTimekeeper/` |
| Mount points of the browser | `~/Library/Caches/PBSTimekeeper/Mounts/` |
| Encryption key created by the app | `~/Library/Application Support/PBSTimekeeper/encryption-key.json` |
| Passwords | Keychain, service `io.github.marvo2011.pbs-timekeeper` |

## Building

Requires Xcode 16 or newer (Swift 6).

```sh
swift test
./scripts/build-app.sh          # build/PBS Timekeeper.app and a zip of it
```

`build-app.sh` downloads the client release named in `CLIENT_VERSION` and checks
its checksum. `PBS_CLIENT=/path/to/proxmox-backup-client` uses a local build
instead, `CODESIGN_IDENTITY` signs with a Developer ID instead of ad hoc.

Ad hoc signed builds get a new signature with every build, so macOS asks again
for Full Disk Access and Keychain access after an update.

Pushes to `master` build a release via GitHub Actions
(`.github/workflows/release.yml`), tagged with the version in `VERSION`. Add a
section for the version to `CHANGELOG.md`, it is used as the release notes.

## License

AGPL-3.0, see `LICENSE`. The bundled proxmox-backup-client is AGPL-3.0 as well,
its source is at https://github.com/Marvo2011/proxmox-backup-client-mac.
