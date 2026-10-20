# Backup Center: versioned engine

Windows backup workbench for development drives and large numbers of small files. It combines metadata inventory, USB link diagnostics, a bounded disk benchmark, and an encrypted, versioned [Restic](https://restic.net/) repository. The English Windows Forms manager provides source selection, progress, ETA, speed presets, and editable bandwidth/memory limits.

The plain copy (`Invoke-FastMirror.ps1`) is a separate engine; both read the same per-folder selection. This document covers the versioned engine.

All application text, reports and recommendations are English-only and use left-to-right layout. Filenames and directory names are preserved in their original language.

## Requirements and installation

- Windows 11, PowerShell 7.2+ (64-bit), and a separate destination volume.
- Restic 0.19.1. `./Install-BackupEngine.ps1` downloads the official Windows x64 archive and checks its pinned SHA-256 before extraction. No PATH changes or administrator installation.
- Python 3.8+ only for generating the optional HTML report. The backup itself has no Python dependency.
- Source may be a physical Dev Drive or a mounted ReFS VHD/VHDX. Back up the files in the mounted drive. Do not copy a live VHDX and assume it is consistent.

```powershell
pwsh -NoProfile -File ./Install-BackupEngine.ps1
Get-Volume | Select-Object DriveLetter, FileSystemLabel, UniqueId
pwsh -NoProfile -File ./Initialize-BackupConfig.ps1 -Source X:\ -DestinationDrive Y
```

Edit `backup.local.json`: set the source, both volume identities, relative source selections, and two absolute key-file paths. Keep the password and recovery file outside the backed-up source. `RepositoryFolder` is a new folder on the selected destination, not the existing mirror. Destination drive-letter changes are supported through volume identity lookup; source identity changes fail closed.

The initializer fills volume identities and private key paths automatically, refuses to overwrite an existing configuration, and starts with non-system top-level folders, except common temporary/package-cache roots. Review these defaults. Alternatively copy `config.example.json` and fill in its placeholders manually. Each entry in `Choices` has a `Mode` (`Mirror`, `Versioned`, `Both` or `Skip`) shared with `Invoke-FastMirror.ps1`; `DefaultMode` covers paths no entry lists. Entries can be folders or single files (for example `README.md` at the root) and can nest. The worker derives its sources from `Versioned`/`Both` entries; `Include` is only kept up to date for other readers. See "Choose per folder" in README.md.

Start `BackupCenter-Advanced.cmd` (or use the main Backup Center window) or:

```powershell
pwsh -NoProfile -File ./Backup-Manager.ps1
```

Profiles are starting points, not a hardware-independent optimum. Review exclusions and deselect anything you do not want backed up. Backup runs create snapshots; source deletions do not automatically delete older snapshots. No scheduled task or automatic retention/pruning is installed. Manual history deletion and optional pruning are available through **History and restore**.

## History browser

`Backup-History.ps1` lists backup versions by date, computer, source folders and exact snapshot ID. Optional From/To dates include the entire selected local calendar day. Browsing loads one directory at a time and displays at most 500 rows per page, avoiding expansion of an entire development drive. The restore selection can contain files and folders from several directories in the same version; opening another version clears it. Selected names are treated literally, including Unicode and bracket characters, rather than as restore wildcard patterns. Restore targets must be new folders outside the configured source and repository. Restic verifies restored content and uses `--overwrite never`.

History deletion always takes explicit full snapshot IDs. The GUI displays the exact deletion list and requires typing `DELETE`; the worker independently validates confirmation, current repository membership and newest-version protection for each computer/source set. Empty, abbreviated, stale and protected selections fail. Equal-time newest versions are all protected. **Select older versions** respects the displayed date range; it is not an automatic retention policy. Removing history makes those versions unavailable, even if some data packs remain until prune. Optional prune removes unreferenced data across the repository, including abandoned data from interrupted backups, and may need temporary free space. Source files are not deleted. All operations use the existing repository worker lock; a concurrent backup or verification causes the new request to fail with a busy/lock error rather than interrupting the existing operation.

## First backup and keys

On the first **Backup**, the worker generates a random 256-bit repository password. A current-user DPAPI-protected copy enables local use. A portable recovery text file is created at `RecoveryKeyPath`; its ACL is restricted to the current Windows user and SYSTEM. The source is not modified.

**Copy the portable recovery key into a password manager or separate offline location.** A DPAPI file depends on the Windows account and machine. If that environment is lost, the portable password is needed to recover the repository. Never commit either file or put the only recovery key inside the encrypted repository. The recovery file is plaintext, protected by its local ACL, so anyone receiving a copy can decrypt the backup.

The UI's preview is a Restic dry run and requires an initialized repository. The first Backup initializes it. Exit code 3 is treated as failure/incomplete backup, even when Restic saved a partial snapshot. Error details remain in that run's logs. Correct the source/exclusions and run again; do not label a partial snapshot as complete.

## Password changes and portable key export

Choose **Password and recovery key** in Backup Center or **Password and recovery** in the advanced window. The window does not contact the repository until an action is chosen. Saving a recovery key exports the current repository password to a new file and records the location in the local configuration. Existing files, linked paths, reserved credential/configuration paths, and paths inside the source, repository or project are refused. Recovery files are created with a protected current-user/SYSTEM ACL before any content is written. Exported files are plaintext and must be kept separately and privately.

Password changes replace the access key currently used by this tool; independently added access keys remain intact. The repository master key, data packs and snapshots are not re-encrypted or recreated. Changing a password does not revoke access to an earlier independently copied repository. This feature does not repair an unhealthy backup drive.

The transaction takes the existing worker lock, validates a 12–1024-character nonempty password, and writes a restricted journal containing only DPAPI-protected credentials and progress metadata. A new Restic key is added with the new password passed through redirected UTF-8 stdin, never as a command-line argument, plaintext temporary file, status field or log entry. The new password must successfully open the repository before the chosen recovery file, DPAPI credential and configuration are saved. Their contents are read back before the original access key is removed. A final authentication verifies the saved password. Snapshot IDs and pack bytes are preserved.

Interruption leaves the protected journal available for **Resume interrupted change**. The worker recognizes an already-created new key and continues rather than blindly adding another one. Other operations fail while the transaction is pending. Resume can use another explicitly selected new recovery path if the original location is unavailable or occupied. Completed journals remain as restricted DPAPI-encrypted local audit files. Older portable recovery files are not deleted; a replaced password no longer opens the current repository once its access key is retired. Save the new recovery file in your independent safe location.

`Test-BackupSecurity.ps1 -DestinationDrive C` creates a small disposable repository on a separate volume from the source. It checks restricted exports, no-overwrite behavior, password rotation, old-password rejection, unchanged snapshot IDs and data hashes, restore and subsequent backup, interruption/resume, and absence of plaintext passwords in logs. It never changes the configured real backup password.

## Resource controls

| Preset | Repository I/O cap | Process committed-memory cap | Go parallelism | File reads | Pack target |
|---|---:|---:|---:|---:|---:|
| Quiet | 15 MB/s | 512 MiB | 1 | 1 | 8 MiB |
| Balanced | 45 MB/s | 1024 MiB | 2 | 2 | 16 MiB |
| Fast | Unlimited | 2048 MiB | 4 | 4 | 32 MiB |

MB/s means decimal bytes; MiB means binary bytes. Bandwidth and memory are editable. The worker converts the rate to Restic's KiB/s units. `0` means no bandwidth cap. Local backend concurrency defaults to 1 to keep a rotational destination's writes mostly sequential, except history deletion with prune, which requires at least 2 connections. Set `BackendConnections` (1–8) in the configuration for an SSD; `Set-BackupDestination.ps1 -Apply` sets 4 when it detects one. Restic packs small objects together and avoids storing identical chunks again; this addresses much of the per-file destination overhead.

- `GOMAXPROCS` limits Go execution parallelism. Quiet/balanced processes use BelowNormal CPU priority. This is not a hard CPU-time quota.
- `GOMEMLIMIT` is a soft Go target at 70% of the selected budget. A Windows Job Object enforces the selected hard per-process committed-memory limit. Exceeding it can cause allocation failure and an incomplete run. Increase the budget rather than assuming every repository fits in 512 MiB.
- Job-object accounting does **not** include the Windows system file cache, the GUI, or unrelated processes. Peak resident memory is reported separately from the committed-memory cap.
- Restic bandwidth limits constrain repository transfers; they do not throttle every source metadata/read operation. Compression and deduplication can make processed source MB/s exceed repository MB/s.
- There is no promise of zero impact on interactive work. Measure with the actual development workload, not just an idle desktop. More RAM does not inherently make a USB HDD faster.
- The current version chooses presets manually; it does not implement an adaptive load controller, pause/resume, or an automatic hard free-space floor during the run. It refuses to start below 5 GiB free. Disk-full/I/O failures are reported.

See [Restic tuning guidance](https://restic.readthedocs.io/en/stable/047_tuning_parameters.html).

## Inventory and benchmark

```powershell
pwsh -NoProfile -File ./Inspect-DevDrive.ps1 -Root X:\ -OutputDirectory ./audit
pwsh -NoProfile -File ./Get-BackupHardware.ps1 -OutputPath ./audit/hardware.json
pwsh -NoProfile -File ./Measure-BackupDisk.ps1 -Drive Y -OutputDirectory ./audit
pwsh -NoProfile -File ./Measure-BackupDisk.ps1 -Drive Y -LinkOnly -OutputDirectory ./audit
```

Inventory reads metadata, not file contents. It traverses accessible directories, records direct sizes for every visited directory, and aggregates the first three path levels. Links are counted but not followed. Access errors are retained in `scan-errors.csv`; system-managed recycle/system-information roots are intentionally not traversed. Reported file bytes are logical lower bounds when access errors exist. They are neither allocated disk usage nor deduplicated unique bytes. ReFS clones, NTFS hardlinks, sparse files, filesystem metadata and inaccessible content explain differences from volume used space. Parent/child aggregate rows must not be summed together.

The benchmark creates one uniquely named temporary file on the selected volume, defaults to at most 512 MiB, stops adding blocks after about 25 seconds, then reads the written portion. It uses aligned 4 MiB buffers, unbuffered native I/O and write-through writes, flushes the handle, closes/reopens it, and deletes only the created file in `finally`. OS file-cache inflation is avoided; the drive/controller's internal cache and physical layout can still affect a short test. It does not measure every disk region or prove sustained whole-drive throughput. A crash can leave the uniquely named benchmark file; no recursive cleanup occurs.

USB diagnostics query the actual device's parent hub and connection index through `IOCTL_USB_GET_NODE_CONNECTION_INFORMATION_EX` **and EX_V2**. Legacy speed information alone can describe a SuperSpeed connection as high speed. EX_V2's operating-speed flags distinguish capability from the active link. If access/query fails, the result is an error, not a claimed speed. Direct USB 3 connection and a suitable cable should be checked before attempting software tuning.

For the optional report, save a baseline measurement as `disk-benchmark-usb2.json` (the filename is historical; label your baseline correctly), then measure the new connection into `disk-benchmark.json`. Supply the official Chart.js 4.5.1 `dist/chart.umd.min.js` bundle to `Build-BackupReport.py`; the generator checks the hash documented in `THIRD-PARTY.md`. Example:

```powershell
python ./Build-BackupReport.py --audit ./audit --hardware ./audit/hardware.json --config ./backup.local.json --chartjs ./audit/chart.umd.min.js --output ./audit/devdrive-report.html
```

The report and application interface are English-only and compares the two provided measurements; it should only label them USB 2/USB 3 when those links were actually verified. Reports are snapshots, not live backup monitors. Live progress belongs to the manager and per-run `status.json`.

## What to preserve

Preserve source code, uncommitted/untracked work, `.git` history, Git LFS objects, manifests/lockfiles, configuration, unique datasets, user-created media, experiment results and release evidence. Treat folder names as clues, not proof of disposability. Do not globally exclude `build`, `dist`, `data`, `bin`, large files or all databases. A successful push is not a backup of everything in a working directory.

Known package caches and virtual environments can usually be recreated if package versions and upstream artifacts remain available. Review exclusions before relying on them: an environment can contain manually edited files or offline-only packages. `pytest-of-*` excludes conventional pytest temporary trees; any personal exceptions need explicit selection. Exclusions never delete the original files or old mirror contents.

Keep Git worktrees with their common Git directory. Restored `.git` pointer files can refer to old absolute paths and may need repair after relocation. Restic stores symlinks without following them; linked-to data outside selected roots needs its own backup selection. Special Windows reparse/cloud placeholders and unusual metadata need explicit restoration testing on the actual filesystems.

Live-file backups are not application-consistent snapshots. This wrapper does not enable VSS. Stop database writers or create supported application exports before backing up critical live SQLite/other databases. An ordinary content copy cannot guarantee consistency of files changing during the run. This is a development-file backup, not bare-metal Windows recovery.

## Verify and restore

Every successful Backup is followed by structural `restic check`. The **Full verification** button runs `check --read-data`, which reads and verifies all repository data and takes additional time. Restic's default pre-upload verification remains enabled.

Incremental backups normally use Restic's metadata change detection. On Windows, unchanged path, size and modification time can cause content to be reused without reading it again. That can miss a source change preserving all those fields. **Re-read all content** in the UI, or `-ForceRead` with `Backup-Worker.ps1`, disables that shortcut. Use it periodically or when source-integrity concerns warrant a full read. Repository verification and a fresh source-content scan answer different questions; neither should be presented as the other.

```powershell
pwsh -NoProfile -File ./Backup-Worker.ps1 -ConfigPath ./backup.local.json -Action Snapshots
pwsh -NoProfile -File ./Backup-Worker.ps1 -ConfigPath ./backup.local.json -Action Check -ReadAllData
pwsh -NoProfile -File ./Backup-Worker.ps1 -ConfigPath ./backup.local.json -Action Restore -Snapshot latest -RestoreTarget C:\Backup-Restore-Test
```

Restore requires a **new, nonexistent folder** outside the source and repository. `--verify` validates restored file contents. Do a real restore test and inspect the application/data. Retain a second independently stored backup; a single USB drive cannot protect against its own failure or theft. The history window offers explicit selected-version deletion and optional prune with confirmation; automatic retention remains unimplemented.

If the original computer/account is lost, install Restic on another Windows computer and use the portable recovery password directly; do not depend on the old DPAPI file or source drive being present:

```powershell
./bin/restic_0.19.1_windows_amd64.exe -r Y:\DevDrive-Backup snapshots
./bin/restic_0.19.1_windows_amd64.exe -r Y:\DevDrive-Backup restore latest --target C:\Recovered-DevDrive --verify
```

Enter the saved repository password at Restic's prompt. Drive letters may differ. Recreate a local configuration only if you want to continue using the manager on that machine.

## Validation and public repository hygiene

```powershell
pwsh -NoProfile -File ./Test-BackupSystem.ps1 -DestinationDrive Y
```

This cross-volume integration test creates disposable source/repository/key directories. It verifies encrypted snapshots, cache exclusions, Hebrew/bracket filenames, SHA-256 of a restored binary, a full data check, old-version restoration, literal selected-file restore, history listing, rejection of unconfirmed/newest/empty deletions, explicit old-history deletion and prune, and restoration of the retained version. Artifacts are printed and left for inspection. It does not touch the configured real repository. `Test-BackupHistory.ps1` tests deletion-plan protection without a repository. The legacy suite is `Test-DevDriveMirror.ps1`.

`Test-BackupStatus.ps1` exercises Windows reader-lock contention. Progress publication uses atomic replacement with bounded retries and is best effort, so a locked progress file cannot abort the backup engine. Each worker also publishes an independent terminal `result.json`; the manager and external monitors should prefer it over `status.json`. Readers should use `Read-BackupStatus` from `Backup.Status.psm1`, which permits delete sharing.

`Test-BackupResourceControls.ps1` checks the native hard memory cap by requesting a 512 MiB allocation inside a process limited to 256 MiB. The integration suite also covers forced rereads of same-size/same-time changes and rejection of wrong source identities and existing restore destinations. Partial restore tests can use `Backup-Worker.ps1 -Action Restore -RestoreInclude /X/Projects/example/README.md`; this is a Restic snapshot-path pattern, not a Windows source path.

Before publishing, review `git status` and the full staged diff. `.gitignore` excludes local configs, audit/reports, engine binaries, logs, protected passwords, recovery keys and temporary test sources. The example config contains placeholders only. Audit CSV/HTML can reveal private names and paths even when no file contents were read. Never use `git add -f` on them. Downloaded Restic is a separate BSD-licensed dependency; its official source/license/release are linked in `THIRD-PARTY.md`.

This wrapper is MIT-licensed (see `LICENSE`). Real-drive backup, full verification, restore evidence and unresolved limitations should remain visible in release notes.
