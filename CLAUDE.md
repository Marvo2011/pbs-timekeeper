# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

PBS Timekeeper: a macOS menu bar app (SwiftUI, macOS 14+, Apple Silicon) for scheduled folder backups to a Proxmox Backup Server, with a timeline browser for restores. It does not talk to the server itself: every operation runs the bundled `proxmox-backup-client` of the macOS port (https://github.com/Marvo2011/proxmox-backup-client-mac, version in `CLIENT_VERSION`).

Folders only, by design: volume roots, `/`, `/Volumes` and system locations are refused (`FolderValidation`), and so are folders nested in each other, since each folder is its own archive.

## Commands

```sh
swift build
swift test                      # swift-testing, TimekeeperCore only
./scripts/build-app.sh          # app bundle + zip in build/, downloads the client release
PBS_CLIENT=../proxmox-backup-client-mac/target/release/proxmox-backup-client ./scripts/build-app.sh
```

## Layout

- `Sources/TimekeeperCore`: no UI, covered by `Tests/TimekeeperCoreTests`.
  - `Config.swift`: `AppConfig`, `BackupState`, `JSONStore`. Decoding must tolerate missing keys.
  - `Commands.swift`: `CommandBuilder`, all client command lines. Uses `--server`/`--port`/`--datastore`/`--auth-id` instead of `--repository`, and secrets go via `PBS_PASSWORD`/`PBS_ENCRYPTION_PASSWORD`/`PBS_FINGERPRINT` in the environment, never in arguments.
  - `ClientRunner.swift`: runs the client. Task cancellation sends SIGINT. After exit only buffered output is read, because `mount` leaves a daemon behind.
  - `Mounts.swift`: FUSE-T mounts (`mount` daemonizes once ready, unmount with `umount`) and `Restorer`.
  - `Snapshot.swift`: `snapshot list --output-format json`.
  - `Schedule.swift`, `Folders.swift`, `Keychain.swift`, `Paths.swift`.
- `Sources/PBSTimekeeper`: the app.
  - `AppModel`: config, scheduler, backup runs.
  - `BrowserModel`/`BrowserView`: the timeline browser.
  - `SettingsView`, `MenuContent`.

## Client facts the app relies on

- One snapshot per run: `backup <archive>.pxar:<path> …` with `--backup-type host --backup-id <id> --change-detection-mode metadata`. Archive names (alphanumerics, `-`, `_`) are assigned once per folder and stored in the config, so they stay stable across snapshots.
- Split archives appear as `<name>.mpxar.didx` + `<name>.ppxar.didx`. `mount`/`restore` accept `<name>.pxar` for both kinds.
- `restore --pattern` uses pathpatterns syntax: `\` escapes `*?[]\`, a leading `/` anchors at the archive root, and a matching directory includes its contents.
- FUSE-T cannot mount on paths containing `:`, so mounts live in `~/Library/Caches/PBSTimekeeper/Mounts/<epoch>-<archive>`.
- Child processes inherit the app's TCC permissions (Full Disk Access) as the app is the responsible process.

## Versioning

`VERSION` holds the app version (semver). Add a `## <version>` section to `CHANGELOG.md` for each version: the release workflow fails without it. Note user-visible changes there. Pushes to `master` publish `v<version>`, and pushes without a bump replace the zip of that release.

## Naming

Do not use Apple's "Time Machine" name, icons or artwork in the app, docs or assets.
