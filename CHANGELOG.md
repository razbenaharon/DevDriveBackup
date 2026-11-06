# Changelog

## Unreleased

- **Keep versions** on the overview: after each versioned backup, keep one version a day for N days, a week for N weeks and a month for N months, and delete older versions (`Backup-Worker.ps1 -KeepDays -KeepWeeks -KeepMonths`). The windows count back from the newest version, so a long pause never empties the history. restic plans it as a dry run; `Get-RetentionRemovals` refuses a plan that drops the version just made or every version of a folder set, keeps the newest version of each set protected, and the versions are then deleted by exact ID with `--prune` and the repository checked again. Only this tool's versions (tag `devdrive`) are considered. A failed clean-up is reported on the finished backup, never turned into a failed backup. Default: every version kept. Tested by `Test-BackupRetention.ps1` against a disposable repository with versions over 200 days.
- **Look** page: themes Light, Dark, Sand, Ocean and High contrast, and *Custom* from four chosen colours (window background, panels, text, main buttons) with secondary text, lines, selection and button text derived to stay readable. Every built-in theme passes WCAG 2.2 contrast for all text the window draws; for a custom theme the page names any pair below the minimum. Dark themes also use Windows' dark title bar, scroll bars and .NET's dark drawing of number boxes and drop-downs. The choice is saved in `%LOCALAPPDATA%\DevDriveMirror\center\appearance.json`. Colour logic in `BackupCenter.Theme.psm1`, tested by `Test-BackupTheme.ps1`.
- The window scales: a larger or maximised window enlarges every position, size and font by the same factor and centres the result; the smallest size is the original 1200 x 800.
- New program icon: the drive label with its status stripe, redrawn as vector with a separate small-size drawing for 16 to 24 px and a light rim that keeps it visible on dark taskbars. Sources, the three routes considered and their contact sheets are in `design/icon`.
- The light theme's secondary text is a little darker (#56636A), so it reaches 4.5:1 on a selected row too (was 4.31:1).
- The speed page no longer hides "No speed test yet..." behind the empty result labels. Disabled buttons stay readable on dark themes. The page tabs are text, not buttons.
- Opening the window lists the drives once instead of three times.
- **Waits for AI sessions**: *Back up now* and *Back up selected source* first check whether Claude Code or Codex sessions worked in the last 10 minutes, judged by their conversation files (`~/.claude/projects`, `~/.codex/sessions`) and running Codex programs, because the app's "running" flag and the list of open programs proved unreliable. If any did, the window names them and offers to wait: it checks every 30 seconds and starts the backup by itself after 10 quiet minutes. *Stop* cancels the wait. `Get-CenterAgentActivity`, tested by `Test-BackupActivity.ps1`.
- **Keep deleted for N backups** on the overview: each plain copy moves files deleted from the source out of the copy into a dated recovery folder beside it and keeps only the newest N recovery folders (`Invoke-FastMirror.ps1 -MoveExtras -KeepRecovery N`). 0, the default, keeps the old behaviour: deleted files stay in the copy. Nothing is moved aside after a run in which robocopy failed.
- **Drive check** page: checks the backup drive in four layers, each with its own verdict. *Quick check* reads the drive's health report (smartctl) and runs its short self-test, reads samples at the start, middle and end, looks for disk, reset and disconnection entries of the last 30 days in the Windows log (matched to this drive through Windows' record of drive arrivals, since disk numbers move between drives), checks the link speed and runs Windows' online file system scan. *Full surface scan* reads the whole disk, notes unreadable and suspiciously slow places, keeps the computer awake, and continues where it stopped. *Long self-test* starts the drive's own full read. Read only; runs as administrator (`Invoke-DriveCheck.ps1`), stopped through a request file because the window cannot end an elevated process.
- `Install-DriveTools.ps1` (and **Install health tool**) downloads smartmontools 7.5 with a pinned SHA-256 and installs only `smartctl` and its drive database into `bin\smartmontools`.
- `Test-PrivacyGuard.ps1` blocks private backup details (volume identifiers, profile paths, personal email, drive models and labels, folder names from your `*.local.json`) from commits, commit messages and pushes; hooks in `.githooks`, also run in CI.
- Plain copy no longer stops after copying when robocopy writes two "extra" records on one line during multi-threaded listing.
- Plain copy and versions never copy Backup Center's own folders of passwords, recovery keys and state, even when the source holds them (for example a whole user folder or drive). Before, a plain copy could put the readable recovery keys on the backup drive.
- *Check backup content* now also finds files that are missing from the plain copy, not only files that differ. It no longer creates an empty copy folder, and it no longer counts as a completed backup.
- Plain copy refuses to run when the drive letter now belongs to a different drive than the profile's backup drive.
- A folder inside a *NeverBackUp* folder is never backed up, even if it is marked for backup itself.
- A selected folder that is missing or became a link now fails the plain copy with its name, instead of being skipped quietly.
- A folder in the source where the copy has a file of the same name (or the reverse) now counts as a copy error instead of passing unnoticed.
- Two sources never share one plain copy folder: a new source never reuses a copy folder already on the drive, and a folder added again keeps its own. Adding two folders with the same name no longer freezes the window.
- A source with no subfolders can now be backed up and checked as a plain copy.
- The first full check of a plain copy is remembered per drive rather than per drive letter, so a new drive with the same letter is checked in full. Each existing plain copy gets one full check after this update.
- The content check skips the folders and names the copy skips, so a folder excluded later no longer shows up as a difference.
- Saving a source's settings waits for, and never overwrites, a password change in progress; if a backup of that source is running, it says so instead.
- **Install health tool** and **Long self-test** now see an installed smartctl (a stray character in its path made the window think it was missing).
- A load level changed during a run now applies to the next step, threads, priority and versions settings alike. A step that cannot start or whose result cannot be recorded is reported as failed instead of leaving the run stuck. Step logs no longer overwrite each other. *Back up selected source* prepares only that source.
- Closing the window asks about a running backup and a running drive check first, and stops nothing unless it really closes. A drive check cannot start while an earlier one (also from a closed window) still runs, and its stop request is kept. A profile that is being checked or speed-tested cannot be removed.
- The speed test button stays off while a test runs, and the result is kept after **Refresh**.
- Look and feel: disabled main buttons stay readable; small status text uses darker colours that meet 4.5:1 contrast; long names end in "…"; links are underlined; the Overview shows the last drive check and why buttons are off when the drive is not connected; drive check findings get more room and scroll only when needed; the Help page has headings.

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
