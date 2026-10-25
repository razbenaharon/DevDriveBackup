# Backup Center

**Backup Center is a free, open-source Windows backup tool for developers.** It backs up a Windows Dev Drive (ReFS or VHDX), code projects and any other folder to external drives, as plain file copies you can open anywhere, as encrypted versioned history, or both. You choose per folder. One window shows how fresh each drive's backup is, lets you set how much CPU and memory a backup may use, and explains every option in plain language.

- **Platform:** Windows 10/11, PowerShell 7.2+
- **Engines:** robocopy for plain copies, [restic](https://restic.net/) for encrypted versions
- **License:** MIT
- **Status:** working and tested on real drives; first public release

## Why Backup Center

Most backup tools either copy everything slowly or hide your files in a format only they can read. Developer drives make this worse: hundreds of thousands of small files, `node_modules` and virtual environments that rebuild anyway, junctions, Git worktrees and files locked by running tools. Backup Center is built for exactly that.

| What you get | How |
|---|---|
| **Fast incremental copies of huge source trees** | robocopy with parallel copying. Only new or changed files are copied (size and time), so a 470,000-file drive updates in minutes. |
| **A copy you can open anywhere** | The plain copy is ordinary files on an NTFS drive. No special software is needed to restore. |
| **History when you need it** | Folders you mark *Versions* go into an encrypted, deduplicated restic repository with every past version. |
| **Per-folder choice** | Each folder is *Plain copy*, *Versions*, *Both* or *Skip*. A folder inside a skipped folder can still be backed up. |
| **Proof, not hope** | *Check backup content* re-reads both sides of every file and compares SHA-256 hashes (plain copy) or verifies all repository data (versions). |
| **Nothing deleted by surprise** | Files you delete from the source are never deleted from the copy; they can be moved aside to a dated recovery folder instead. |
| **Load control for your hardware** | Detects your processor and memory and offers Light, Balanced, Strong and Maximum levels, or your own threads, memory limit, parallel files and priority. You can lower the load while a backup runs. |
| **Several backup drives, each with its own content** | One profile per drive, recognised by the drive itself rather than its letter. |
| **Knows how fresh each backup is** | The age of the last complete backup, coloured green, blue or orange against the number of days you choose. |
| **Skips what rebuilds** | `node_modules`, `.venv`, `__pycache__`, test and build caches, recycle bin and system folders are skipped by default; your own skips go in a personal settings file. |
| **Safe with developer drives** | Junctions and symlinks are not followed, so nothing is copied twice. Refuses a backup onto the same physical disk as the source, including the disk that holds a Dev Drive VHDX file. |
| **Measures the backup drive** | Reports model, health, file system and the real USB link speed (USB 2, 5 Gbit/s, 10 Gbit/s), and runs an unbuffered read/write benchmark. |

## Install

1. Install [PowerShell 7.2 or newer](https://aka.ms/powershell).
2. Get the code: `git clone https://github.com/razbenaharon/BackupCenter.git`, or download the ZIP and run `Get-ChildItem -Recurse | Unblock-File` in the folder so Windows allows the scripts.
3. Only if you want versioned history: `pwsh -NoProfile -File ./Install-BackupEngine.ps1` downloads restic 0.19.1 into `bin\` and checks its pinned SHA-256.
4. Optional: `pwsh -NoProfile -File ./New-BackupCenterShortcut.ps1` puts a **Backup Center** shortcut with the program icon on the desktop.

No administrator rights, PATH changes or services are needed.

## Quick start

1. Connect the backup drive (NTFS recommended) and start `BackupCenter.cmd`.
2. **New profile...** and choose the drive.
3. On **What to back up**, **Add folder...** for each drive or folder, and set each subfolder to *Plain copy*, *Versions*, *Both* or *Skip*.
4. Choose a **Computer load** level and press **Back up now**.

The first plain copy is verified automatically, file by file. After that, back up whenever you like; the overview shows how long ago the last complete backup was.

## How it works

**Plain copy** (`Invoke-FastMirror.ps1`) runs robocopy per selected folder with `/E /COPY:DAT /DCOPY:DAT /XJ`, retries once, and skips caches and links. A file that stays locked is counted and reported without stopping the run. Files that exist only in the copy are reported, and moved to `<copy folder>-recovery\<date>` only when you ask for it (`-MoveExtras`). Verification hashes both sides in parallel.

**Versions** (`Backup-Worker.ps1`) run restic with a random 256-bit password stored for your Windows account (DPAPI) plus a portable recovery key file, a hard memory cap (Windows Job Object), CPU and I/O limits, and a structural `restic check` after every backup. Restore always goes to a new folder and verifies restored content.

**Folder modes** are stored once per source and read by both engines (`Backup.Selection.psm1`). The most specific entry wins, so `Projects` = Both with `Projects\big\cache` = Skip works as expected.

| Mode | Plain copy | Versions |
|---|---|---|
| Plain copy | copied | — |
| Versions | — | backed up |
| Both | copied | backed up |
| Skip | — | — |

**Load levels** are computed from your hardware. On a 12-thread, 40 GB laptop, for example: Light = 2 threads, 1 GB, 4 files at once, below-normal priority; Maximum = 11 threads, 8 GB, 32 files, normal priority.

## Files

| File | Purpose |
|---|---|
| `BackupCenter.cmd`, `Backup-Center.ps1` | The main window |
| `BackupCenter.Data.psm1` | Profiles, sources, history, freshness, load levels |
| `Invoke-FastMirror.ps1` | Plain copy and verification |
| `Backup-Worker.ps1` | Versioned backup, check, restore, history, keys |
| `Backup-History.ps1`, `Backup-Security.ps1` | Versions and restore; password and recovery key windows |
| `BackupCenter-Advanced.cmd`, `Backup-Manager.ps1` | Advanced window for one versioned source |
| `Set-BackupDestination.ps1`, `Measure-BackupDisk.ps1` | Drive inspection, USB link speed, benchmark |
| `Inspect-DevDrive.ps1`, `Build-BackupReport.py` | Optional size inventory and offline HTML report |
| `profiles.local.json`, `jobs\*.local.json`, `backup.local.json` | Your personal settings (git-ignored) |

Personal skips go in a job file: `Exclude` takes folder names (wildcards allowed) or paths below the source, and `NeverBackUp` lists folders that are never backed up by either engine, such as a folder holding credentials. See [config.example.json](config.example.json) and [BACKUP-SYSTEM.md](BACKUP-SYSTEM.md).

## Frequently asked questions

**How do I back up a Windows Dev Drive?**
Add the Dev Drive (for example `E:\`) as a source in Backup Center and back it up to an external drive. Back up the files inside the mounted drive, not the `.vhdx` file while it is in use. Backup Center refuses to put the backup on the physical disk that holds the VHDX.

**Does it compress my files?**
The plain copy does not; it is an ordinary file-for-file copy. Versions are compressed, deduplicated and encrypted by restic.

**Does every backup read all my files again?**
No. Plain copies compare size and modification time and copy only what changed. *Check backup content* is the separate, slower step that reads everything and compares hashes.

**What happens to files I delete?**
They stay in the plain copy. Versions keep them in older snapshots. Nothing on the backup drive is deleted automatically.

**Will it slow down my computer?**
Choose the load. Light uses about a sixth of your processor threads at below-normal priority so your programs come first; you can switch levels during a backup.

**How do I restore?**
Plain copy: open the folder on the backup drive and copy files back. Versions: **Versions and restore** in the window, or `restic restore` with the recovery key on any computer.

**Can I use several backup drives?**
Yes. Each drive has its own profile with its own folders and its own freshness.

**Is there a scheduler or reminder?**
No, by design. You decide when to back up; the window shows how old each backup is.

## Tests

Each test uses disposable folders and uniquely named folders on the destination drive and never touches your real backups:

```powershell
pwsh -NoProfile -File ./Test-BackupCenter.ps1 -DestinationDrive Y      # window data layer, both engines
pwsh -NoProfile -File ./Test-BackupSelection.ps1 -DestinationDrive Y   # per-folder modes in both engines
pwsh -NoProfile -File ./Test-BackupSystem.ps1 -DestinationDrive Y      # versions, restore, history, prune
pwsh -NoProfile -File ./Test-BackupSecurity.ps1 -DestinationDrive Y    # password change and recovery keys
```

`Test-BackupHistory.ps1`, `Test-BackupStatus.ps1`, `Test-BackupSecuritySafety.ps1` and `Test-BackupResourceControls.ps1` need no drive and run in CI.

### Keeping your own details out of a fork

`Test-PrivacyGuard.ps1` refuses volume identifiers, user-profile paths, personal email addresses and force-added git-ignored files. On your computer it also reads your git-ignored `*.local.json` files and `%LOCALAPPDATA%\DevDriveMirror\hardware.json` and refuses their specific values (drive models and labels, key identifiers, folder names, computer name), without ever storing them in the repository. CI runs it on every push; to run it before every commit and on every commit message, turn on the hooks once per clone:

```powershell
git config core.hooksPath .githooks
pwsh -NoProfile -File ./Test-PrivacyGuard.ps1 -ListTerms   # show the private values it protects
```

## Limitations

- Windows only. The window and messages are in English; file names in any language are preserved.
- Backups read live files; there is no VSS snapshot. Close databases or export them before backing them up.
- The plain copy keeps file contents, timestamps and basic attributes, not NTFS permissions or alternate data streams.
- One backup drive cannot protect against its own loss. Keep a second drive or copy somewhere else.

## License

MIT, see [LICENSE](LICENSE). restic and Chart.js are separate projects under their own licenses, see [THIRD-PARTY.md](THIRD-PARTY.md).
