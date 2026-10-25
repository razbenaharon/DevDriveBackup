# Changelog

## Unreleased

- `Test-PrivacyGuard.ps1` blocks private backup details (volume identifiers, profile paths, personal email, drive models and labels, folder names from your `*.local.json`) from commits, commit messages and pushes; hooks in `.githooks`, also run in CI.
- Plain copy no longer stops after copying when robocopy writes two "extra" records on one line during multi-threaded listing.

## 0.1.0 — first public release

### Backup Center window
- One profile per backup drive, recognised by volume identity, each with its own sources.
- Any folder or drive as a source; per-folder modes Plain copy, Versions, Both or Skip, shared by both engines.
- Age of the last complete backup with colour states against a "Mark as old after" period; no scheduler or reminder by design.
- Computer load levels (Light, Balanced, Strong, Maximum, Custom) computed from the detected processor and memory; priority can be changed while a backup runs.
- Back up, back up one source, check backup content, stop, open the plain copy, versions and restore, password and recovery key.
- Drive speed test without freezing the window, recent runs with duration and average speed, explanations on every page.
- Unexpected errors are shown in plain words and logged to `%LOCALAPPDATA%\DevDriveMirror\center\ui-errors.log`.

### Plain copy (`Invoke-FastMirror.ps1`)
- robocopy-based incremental copy with parallel files, junction/link skipping and cache skipping.
- Locked files are counted and reported without stopping the run; totals are read in any Windows language.
- Files only in the copy are reported and, on request, moved to a dated recovery folder; never deleted.
- `-Verify` compares SHA-256 of every copied file; `-VerifyOnly` checks without copying. Files that exist only in the copy are reported separately from content differences.
- Refuses the source's own disk and the disk holding a Dev Drive VHDX, and a source drive whose volume identity changed.
- Personal skips from the configuration's `Exclude` (names and paths) and `NeverBackUp`.

### Versions (`Backup-Worker.ps1`, restic 0.19.1)
- Encrypted, deduplicated snapshots with DPAPI-protected password, portable recovery key, hard memory cap, CPU and I/O limits, and `restic check` after every backup.
- A folder selected inside a skipped folder is included (restic would otherwise drop it).
- Only a backup creates a repository; history and checks report a missing repository instead of creating an empty one.
- Restore below protected folders succeeds with a warning when only parent-folder timestamps cannot be set.
- Recovery keys default to a local, unsynced folder in the user profile.
- History browsing, selective restore, deletion with typed confirmation and optional prune, and resumable password changes.

### Tools
- `Set-BackupDestination.ps1` and `Measure-BackupDisk.ps1`: drive model, health, file system, USB link speed and benchmark.
- `New-BackupCenterIcon.ps1`, `New-BackupCenterShortcut.ps1`: program icon and desktop shortcut.
- Launchers check for PowerShell 7.2+ and show problems instead of failing silently.
