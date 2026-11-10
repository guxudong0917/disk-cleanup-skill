---
name: disk-cleanup
description: Windows disk space analysis and cleanup for any drive (C:, D:, ...). Scans with WizTree and keeps the snapshots for reuse and before/after comparison, finds what grew, leftovers of uninstalled software, stray installers, duplicate files, regenerable project artifacts (node_modules, .venv, Unity/Unreal caches), crash dumps, browser caches and broken uninstall entries, reports them as "safe to delete / needs your action / your call / don't touch", and deletes only after the user confirms. Use it whenever the user mentions a full or almost full drive, low disk space, cleaning up the PC, what is taking space, whether a folder can be deleted, leftovers after uninstalling, an uninstaller that "cannot find the file", or what changed on a drive recently - also in Chinese, e.g. C盘满了, D盘快满了, 磁盘空间不足, 清理电脑, 什么在占空间, 这个文件夹能删吗, 卸载不干净, 残留文件, 最近C盘多了什么 - even if the word "clean" is never used.
---

# Windows disk cleanup

Goal: find out where the space went with as few scans as possible, then free space safely after the user confirms. Always report in the user's language (the user is often Chinese-speaking; keep Windows/app UI labels in the language the user sees on screen).

## Core rules (each one comes from a real mistake)

1. **Measure sizes with WizTree, never with recursive PowerShell.** WizTree reads the NTFS MFT as admin: a whole drive in 10-25 s. `Get-ChildItem -Recurse` over system folders takes minutes and can hang on odd folders. Even "just a quick look at one folder" goes through the snapshot. A non-recursive listing of one folder is fine.
2. **Keep snapshots in one folder on a non-system drive and reuse them** (default `<first non-system drive>:\WizTreeScans`, or `ScanDir` in the local config). Answer follow-up questions from the newest snapshot; rescan only when the data must reflect something that just changed. Saving scans on C: and deleting them afterwards wastes both C: space and the next rescan.
3. **Report first, delete later.** List path, size and evidence; wait for an explicit yes; delete exactly the group the user approved. Personal data goes to the Recycle Bin by default (`Remove-Paths.ps1` decides), so a wrong call can be undone; only caches and verified regenerable artifacts are deleted outright.
4. **"Leftover" needs evidence.** Before calling something a leftover, check the uninstall registry, Start Menu shortcuts, running processes and when anything inside was last written. A folder still being written to with no install record is probably a portable app: that is "your call", not "safe".
5. **Prefer the app's own cleanup.** Chat apps, vendor PC-manager tools and browsers clean their data more safely than deleting folders (deleting chat media by hand makes messages show "expired").
6. **Elevated work goes into a .ps1 run with `-File`, output to a log file.** Never cram a long command into `-Command`: one quoting mistake leaves an elevated process hanging invisibly, with no UAC prompt and no output.
7. **Keep the scripts' default thresholds (`-MinMB 20`).** Raising them to shorten output has hidden 21 MB leftovers and 95 MB installers. If output is long, use `-Section` / `-OutFile`.
8. **Scripts produce candidates; conclusions come from reading every row and following up** (section 3c). Different models given the same snapshot produced very different reports, and nearly all of the difference came from whether they took one more step after seeing a result.
9. **Read the local notes first, update them last** (section 0 and 6). A fresh session without that context re-lists things the user already decided to keep and forgets what earlier sessions found.
10. **Something that looks like malware is not cleanup.** Random or system-imitating folder and file names, a signed exe next to an unsigned DLL, folders an administrator cannot read: stop, check it read-only (section 3d) and report it at the top, apart from the space findings. Never delete it as "junk" - that destroys the evidence and leaves the persistence (task, service) behind, which recreates it. A cleanup run found a live backdoor this way, only because one extra check was made on an odd folder name.
12. **Run as the user, outside any agent sandbox, and treat a failed check as "unknown", never as "nothing found".** Sandboxed agents (e.g. Codex) run commands under a separate account: TEMP is not writable (the snapshot reader cannot compile), the user's folders, HKCU (Run entries, shell-folder redirection) and Start Menu resolve to that account, and free space reads as 0. Check first: `whoami` must be the user who owns the disk; `$env:USERPROFILE` must be theirs. If not, ask to run unsandboxed, or mark every user-context result as "could not verify". Scripts exit with code 2 (snapshot reader unavailable) or 3 (folder unreadable): stop and report it; do not read their output as empty.
11. **Mask personal identifiers in reports.** File names often carry ID-card, student or employee numbers, phone numbers and real names (`<student no.>_<name>_report.docx`). In what you show, keep just enough to recognise the file (`2021******_X**_report.docx`); use the full path only in the delete list and the local notes. Never copy them into anything that leaves the machine.

## Local, machine-specific data (not part of the skill)

- `%USERPROFILE%\.disk-cleanup\config.json` (or `$env:DISK_CLEANUP_CONFIG`): `ScanDir`, `WizTreePath`, `Keep`. Scripts read it automatically; all fields optional.
- `<ScanDir>\disk-notes.md`: the user's decisions and facts found on this machine (see section 6). Created by you on the first run.
- `<ScanDir>\*.csv`: WizTree snapshots and reports.

## Scripts

All in `scripts/`, Windows PowerShell 5.1. Run as `powershell -NoProfile -ExecutionPolicy Bypass -File <script> <args>` with absolute paths. Every script that reads a snapshot uses the C# reader in `WizTreeCsv.ps1` (a files snapshot has ~1.3 M lines: ~30 s in a PowerShell loop, ~3 s in C#). When you write ad-hoc analysis code, do the same: filter with `Read-WizTreeCsv` / `[WtCsv]::Read(...)` by size, date or regex first, never loop over snapshot lines in PowerShell.

| Script | Purpose | Admin |
|---|---|---|
| `Invoke-WizTreeScan.ps1` | Run WizTree, export `-Mode folders` or `files` to the scan folder; reuses a snapshot younger than 6 h unless `-Force`. Keeps the newest 3 per drive and mode (newest = current state, older = baselines) | WizTree prompts UAC |
| `Get-FolderSizes.ps1` | Size ranking of the direct subfolders of one or more `-Path`s (one snapshot read per drive) | no |
| `Compare-Scans.ps1` | Diff two folder snapshots: what grew, shrank, appeared | no |
| `Find-Leftovers.ps1` | Folders of uninstalled software (system drive: Program Files, ProgramData, AppData; other drives: `X:\Program Files*` and top-level folders that contain .exe files), Start Menu shortcuts whose target is gone, startup (Run) entries whose program is gone, and loose big files in the root of non-system drives | no |
| `Find-OldFiles.ps1` | From a files snapshot: installer-like files and archives (plus the folders that hold them), crash dumps anywhere, possible duplicate user files (same size; archive ≈ sibling file; archive next to an extracted folder of the same name), big files untouched for months, or `-RecentHours N` recent writes. `-Drive`, `-Section installers\|dups\|old`, `-OutFile` | no |
| `Find-ProjectArtifacts.ps1` | Personal-data drives: work folders with size and last activity, projects (Unity, Unreal, Node, Python, Gradle, Visual Studio, Premiere caches) and their **regenerable** parts, similar-named versions and packaged builds; CSV report with a Decision column, `-DeleteList` for cold projects, `-NoReport` for read-only runs | no |
| `Test-Installer.ps1` | Is this .exe/.msi an installer? Name, version info, installer-framework markers (NSIS, Inno, WiX...), same-folder program components, matching installed program and version; `stale-copy` for an older copy of a program installed elsewhere; `identity-mismatch` when the name claims a product its metadata does not confirm (security, section 3d). `-WithSignature` adds the signer (slow) | no |
| `Find-BrokenUninstallEntries.ps1` | Settings > Apps entries whose uninstaller is gone; `-Remove` exports a .reg backup, then deletes | for `-Remove` |
| `Remove-Paths.ps1` | Delete an approved list (`-ListFile`). `-Recycle auto` (default): personal-data areas (Desktop, Documents, Downloads, Pictures, Videos, Music incl. redirected locations, any non-system drive) go to the Recycle Bin, unambiguous artifacts are deleted; `-Recycle never` for verified regenerable lists | depends on paths |

Elevated run template (for `Remove-Paths.ps1` on system paths, `Find-BrokenUninstallEntries.ps1 -Remove`):

```powershell
Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$script`"",'-ListFile',"`"$list`"",'-Log',"`"$log`""
Get-Content $log
```

Tell the user a UAC prompt is coming. If a run times out without a log, check for a stuck elevated powershell before retrying; if the log says the prompt was cancelled, nothing ran - ask before trying again.

## Workflow

Do only what the question needs. "Can I delete this folder?" = snapshot lookup + install-status check.

### 0. Read the notes
Read `<ScanDir>\disk-notes.md` if it exists.
- **Keep**: never list these as deletable; one line under "don't touch" is enough.
- **Identified, awaiting the user's decision**: check each item still exists (`Test-Path` or snapshot) and **re-list every surviving item in this report**. Earlier sessions found them; the user may simply not have decided yet. (A run once read notes saying "the old copy of app X in D:\ can be deleted" and still did not report it.)
- **User to-do** (e.g. disabling hibernation): remind once if still pending.
- **Known facts are clues, not truth.** Use them to save work, but when evidence (version numbers, hashes, registry, running processes) contradicts them, trust the evidence, say so in the report and fix the notes in step 6. Notes have been wrong before (an old portable copy recorded as "the program in use"; a Node.js installed into a drive root recorded as "a single node.exe").

### 1. Current state and scans
- Free space per drive: `. <scripts>\WizTreeCsv.ps1; Get-DriveSpace` (`Get-PSDrive` silently returns 0 in some restricted contexts; "unreadable" means say so, never "0 GB free"). Compare with the last value in the notes: a big difference means the user changed things; rescan with `-Force`.
- `Invoke-WizTreeScan.ps1 -Drive C -Mode folders` (reused if < 6 h old). Run `-Mode files` only when you need individual files (installers, dumps, duplicates, recent writes).
- If an older folder snapshot exists, run `Compare-Scans.ps1` and tell the user what grew since then - usually the first thing they want to know.
- **Other drives**: same scripts with `-Drive D`. Non-system drives hold mostly the user's own data (photos, videos, projects, game libraries, chat archives). That is not junk: report sizes plus obvious duplicates, stray installers and leftovers; the user decides. Programs are often installed straight into `X:\SomeApp` or even `X:\` itself; those are what uninstallers leave behind.

### 2. Find the big items
`Get-FolderSizes.ps1` level by level: `C:\` → `C:\Users\<user>\` → `AppData\Local` / `Roaming` → `Program Files` / `ProgramData` / `Windows`. `hiberfil.sys` / `pagefile.sys` are files in the root: `Get-ChildItem C:\ -Force -File`.

**"Not found" is not "gone".** `Test-Path` / `Get-Item` return False / "Cannot find path" for `hiberfil.sys`, `pagefile.sys` and `swapfile.sys` even though they exist, and folders such as system crash-dump or service-profile directories answer "Access is denied". Confirm existence from the parent listing (`Get-ChildItem <parent> -Force`) or the snapshot, and report "could not verify" for denied paths - never mark such an item as deleted in the notes.

### 3. Categories (details in `references/known-locations.md`; China-specific apps in `references/china-apps.md`)
- **Regenerable caches**: package-manager caches, old runtimes, half-installed extension folders, browsers downloaded by test tools.
- **Leftovers of uninstalled software**: `Find-Leftovers.ps1`, then verify (rule 4). Status: `likely-leftover` (no install record, nothing written for 60 days - still verify: installed on another drive? different name?), `unknown-recent` (written recently: portable app or an updater - your call), `tool-data` (npm, uv, ... data - not a leftover), `running` (in use - don't).
- **Updater caches of installed apps**: `AppData\Local\<x>-updater\installer.exe`, `...\update\*.exe` are downloaded installers; safe, they are re-downloaded on the next update.
- **Stray installers and long-untouched big files**: `Find-OldFiles.ps1`. A program binary that has not changed for a year is not an installer.
- **Crash dumps**: `Find-OldFiles` lists them even inside `C:\Windows\`. The "recent writes" view never shows them because they are often months old.
- **Broken uninstall entries**: `Find-BrokenUninstallEntries.ps1` (tiny, but clutter Settings > Apps).
- **System-level items**: hibernation file, Windows Update caches, component store - system tools only.
- **Two versions side by side**: old and new version of the same app, the old one's data still on disk.

### 3b. Personal-data drives: old projects and stray installers
Leftover detection does not see the user's own work. In this order:
1. **Regenerable parts** (nothing is lost): `Find-ProjectArtifacts.ps1 -Drive D -DeleteList <txt>` (`-NoReport` for analysis only). Clean `cold` projects only; ask about `cold-in-active-folder`; never touch `active`. **Read the delete list before deleting**: nothing inside `node_modules\`, nothing next to `node.exe` / `python.exe` (a program install, not a project). The script excludes those, but it decides by folder names; a glance is cheap, deleting a Node install's npm is not. When the Note column says a `.venv` holds non-environment data, delete only the listed `Lib` / `Scripts` / `Include`. Warn that a Python venv needs its dependencies re-downloaded. Packaged builds (e.g. `Engine\Binaries` of a packaged Unreal game) are required at runtime; the script tells source projects from builds by the presence of `*.uproject`.
2. **Cold data**: large media or work untouched for long - suggest compressing and moving to cloud/external storage rather than deleting; the user decides per item (Decision column of the CSV report).
3. **Duplicates and packaged outputs**: `project` vs `project 5.7`, "packaged build (runnable)", `copy` / `backup` - report only.
4. **Companion files of software no longer used**: e.g. without a video editor installed, its project files, media caches, peak files, previews and autosaves can go - **keep footage and exported videos**. Show the top-level contents so the user sees what goes and what stays.
5. **Stray installers**: run `Test-Installer.ps1 -Folder` on **every folder that may hold installers**, not only on the files `Find-OldFiles` named: each drive root, Desktop, Documents, Downloads (their real, possibly redirected paths) and every folder `Find-OldFiles` lists under "folders holding installer candidates". Name rules miss installers like `SomeApp-win32-x64-user-5.9.3.exe` or `AppName_7.27.0.5.exe`; only the folder-wide check sees them. Verdicts: `installer` - removable; `stale-copy` - old copy of a program installed elsewhere, removable as a whole set (your call); `likely-installer` - confirm with the user; `program` / `program-component` (same company/product as a program installed in that folder, or its uninstaller - e.g. WinRAR installed straight into `D:\` with its `Uninstall.exe`) - never. Tell the user the evidence (Signals column). In a drive root, `install.exe`, `VC_RED.MSI`, `eula.*.txt`, `install.res.*.dll`, `globdata.ini`, `vcredist.bmp` dated 2007-11-06 are junk unpacked by the VC++ 2008 redistributable installer.
6. Deleting: regenerable lists with `-Recycle never`; other personal data keeps the default (Recycle Bin) - tell the user the space is freed only after emptying it.

### 3c. Follow up on what you see (everything the compared runs missed is in this table)
| You see | Then |
|---|---|
| An archive next to a file of almost the same size (within 1%), e.g. `clip.zip` 1701 MB next to `clip.mp4` 1703 MB | List the archive (zip: `Open-ZipArchive` from `WizTreeCsv.ps1`, reads only the directory and decodes legacy-code-page names such as GBK correctly - plain `ZipFile::OpenRead` returns garbled names on UTF-8 or foreign-locale systems, and every name comparison then fails; rar/7z: `UnRAR.exe l` / `7z l`). **Hash the entry inside the archive** (zip: SHA256 of `$entry.Open()`), not the archive file - the archive's own hash never equals the original's. Same hash = duplicate; keep the plain file |
| An archive next to a folder of the same name (`A.rar` + `A\`; `Find-OldFiles -Section dups` shows FolderMB), or an archive the notes call "already extracted" | **Equal sizes prove nothing** (a course archive matched its folder's size while two files inside had been edited). Zip: `. WizTreeCsv.ps1; Compare-ArchiveFolder -Archive A.zip -Folder A\ -Hash` - only `identical` makes the archive redundant; `differs` = the archive holds older originals (your call, say which files differ); `folder-has-more` = edited/added after extraction; `partial` = entries missing (nested archives get extracted into folders, so check those by hand). rar/7z: compare `UnRAR.exe lt` / `7z l -slt` listings (name + size), and hash a sample before calling it redundant |
| Two files with the same name and size (possible duplicates section) | Confirm with `Get-FileHash`. If one copy is inside a chat app's data folder, suggest deleting the other one: deleting the chat copy breaks the file in the conversation |
| One installer in a folder | Run `Test-Installer.ps1 -Folder` on the **whole folder**; there are usually more |
| A browser profile folder on any drive (`...\Chrome\User Data`, `...\Edge\User Data`) | Size each profile's `Cache`, `Code Cache`, `GPUCache`, `Service Worker\CacheStorage` from the snapshot (query in `known-locations.md`); report as "needs your action": clear cached images and files in the browser, every profile |
| Every drive | Size `X:\$RECYCLE.BIN` from the snapshot. **Do not count it through the Shell API**: that only shows the current account's items and once reported "empty" for a bin holding 0.5 GB |
| A big folder in the work-folder list that is **not a project** | Say what it is: virtual disk (`*.vhdx`, WSL/Docker - compactable), phone backup, an app's temp folder, intermediate output of a repair/convert tool (`recovered.h264`), data of an old app version. See the reference files |
| `likely-leftover` portable apps (e.g. `SomeTool-5.6-win`) | Your call; say it is portable and when it was last used |
| An old version of an app, or an app replaced by another one that is in use: `Test-Installer` says `stale-copy`, or an archive/folder named like an app (`SomeApp-1.2.zip`, `*-win`, `*_portable`) while the registry or `Get-Process` shows another version of the same or an equivalent product | Use versions, install location and running processes as evidence; list it with its archives and extracted copies under "your call" as "replaced by X". Delete the whole set (look for an `uninstall.log` next to it), not only the exe |
| Crash dumps (`Find-OldFiles` "Crash dumps" section; `C:\Windows\Temp`, `C:\Windows\ServiceProfiles\*\AppData\Local\Temp`, `LiveKernelReports`, `Minidump`, `*.dmp`) | Look at this section separately - recent-write checks never show old dumps. Deletable unless someone is debugging that crash (system folders need admin). To see what crashed, read the minidump header (`MDMP`, module list); a zeroed header means an unfinished dump that no debugger can open |
| Dead Start Menu shortcuts (end of `Find-Leftovers`) | Leftovers; remove them together. Shortcuts with invisible characters in the name or targets in odd random-looking paths (e.g. `C:\SomeLogs\x7Ab\...\setup.exe`): go to section 3d before calling them leftovers |
| Dead startup (Run) entries (end of `Find-Leftovers`) | Leftovers of removed apps; remove with the related folders. They take no space but Windows tries to start them at every logon |
| You delete a portable / "green" app or a repacked install | Also look for its uninstall entry and Run entry pointing into that folder (repacks often register both); remove them in the same step, or `Find-BrokenUninstallEntries` will find them later |
| An installed app's folder with versioned or backup copies (`*.old`, `*.bak`, `*_old`, `backup\`, `<version>\` folders older than the running version) | Update backups the updater did not clean; deletable with the app closed once the current version runs. Check which version is running first |
| Folders named like logs, traces or diagnostics (`*Logs`, `*Trace*`, `Diag*`, `Crashpad`, `*Dumps`) that are large | Size them from the snapshot; contents are deletable unless someone is debugging; tell the user if a tool keeps writing GBs (it may have tracing switched on) |
| Store apps (`Get-AppxPackage`) the user no longer uses or the vendor discontinued | List with size (`C:\Program Files\WindowsApps` in the snapshot); "your call"; uninstall through Settings, never by deleting folders |
| A folder name you cannot explain in `Public`, `ProgramData`, a drive root or `AppData` (random, or imitating Windows/Microsoft) | Section 3d. Do not size it and move on |
| Loose files in a drive root (end of `Find-Leftovers`) | GUID-named `.tmp` files (read the title/author with `WindowsInstaller.Installer` COM `SummaryInformation`; often copies of a failed MSI install); archives (already extracted somewhere?); a whole program unpacked into the root (`uninstall.log`? older than the installed version?); model weights, slides and other personal files - your call |
| `Installed` column of `Test-Installer` | `same` / `older`: that version or newer is installed, the installer is redundant; `NEWER`: maybe a pending update, ask; empty: not installed, ask whether the user still wants it; `publisher only`: just the vendor matched (a vendor makes many products) - check the product yourself |
| Script output is long or cut off by the tool | Do not stop at the first half: `Find-OldFiles -Section ...` or `-OutFile x.csv`; pass several `-Path`s to `Get-FolderSizes` |
| Results contradict each other (one script shows fewer items, something disappears) | First suspect your own ad-hoc filtering or truncated output (e.g. in `Format-Table` the widest number has no leading space, so a `'^\s+\d'` filter drops it). Re-run and read the full output before concluding |

Before reporting, walk through this table: every row is either done or you can say why it does not apply.

### 3d. Suspicious items (security, not space)
**Signals** - any one is enough to look closer:
- Folder or file names that are random (`C:\AbCLogs\x7Ab\`, `lc3ii.exe`, `NSxJE.TQv`) or imitate Windows/Microsoft in a place Windows never uses: `C:\Users\Public\Documents\x86-Microsoft-Windowsdata`, `AppData\Local\Microsoft\EdgeUpdate` (the real one lives under `Program Files (x86)\Microsoft`), a folder in a drive root named like a log or driver folder.
- Executables named like system processes with a letter added or changed (`StartMenuExperienceHostker.exe`, `WUDFCompanionHoste.exe`), or running from `Public`, `ProgramData`, `Temp` or a drive root.
- A **signed** exe next to an **unsigned** DLL that it loads (DLL side-loading: the trusted exe runs the attacker's DLL); data files with meaningless extensions next to it.
- Folders or files that an administrator gets "access denied" on although they are not system files; scheduled tasks with system-sounding names (`WindowsPowerShell.WbemScripting.*`) that an administrator cannot delete; services whose binary lives in a user-writable folder.
- Shortcuts with invisible characters in their names (see 3c).

**Checks** (read-only, no deletion):
1. List the folder with `Get-ChildItem -Force` (hidden files) and `Get-AuthenticodeSignature` on every exe/dll; record SHA256 hashes.
2. Persistence pointing at that path: `Get-ScheduledTask` (match `Actions.Execute` / `Arguments`), `Get-CimInstance Win32_Service` (`PathName`), `HKCU`/`HKLM ...\CurrentVersion\Run`, Startup folders.
3. Activity: `Get-CimInstance Win32_Process` by `ExecutablePath`; `Get-NetTCPConnection -OwningProcess <pid>` for remote addresses.
4. What Defender already knows - **filter, the full history can be 10,000+ lines**: `Get-MpThreat` (one row per threat: name, severity, active or not), then `Get-MpThreatDetection | Where-Object InitialDetectionTime -gt (Get-Date).AddDays(-30) | Select-Object InitialDetectionTime, ThreatID, ActionSuccess, @{n='Res';e={$_.Resources | Select-Object -First 2}}`; `Get-MpComputerStatus | Select-Object FullScanAge, FullScanEndTime` (`FullScanAge` 4294967295 = a full scan never completed). A red alert that vanished usually means it was quarantined or the threat was "allowed".
5. A file whose name claims a product that its metadata does not confirm (`Test-Installer` verdict `identity-mismatch`, e.g. `SomeApp_2.4.4.exe` described as "FormCeo", version 1.0.0.0, unsigned) is a possible fake installer - often the infection source. Hash it and look for what it dropped (files created around its timestamps in `Public`, `ProgramData`, drive roots).

**Report** it as a separate first section, "possible security issue", with the evidence (names, signatures, hashes, persistence, connections) and suggest a Defender full or offline scan. Act only with the user's yes, in this order: stop the process, disable the task/service, block remote addresses in the firewall, move the files to a quarantine folder (not the Recycle Bin), then remove the persistence; delete only after the scan agrees. A task or registry key whose ACL locks out Administrators can be removed by a one-off scheduled task that runs a `-File` script as `SYSTEM`; avoid `reg.exe` in hidden elevated runs (it can wait on an invisible prompt). Record hashes and what was done in the notes. Afterwards tell the user to change passwords **from another, clean device** and to sign out all other sessions: stolen login cookies stay valid after a password change on many sites.

### 4. Report
If section 3d found anything, put it first, separate from the space findings. Then four groups, a table each - size, path, what it is, evidence - then the total that can be freed and the single biggest win. Mask personal identifiers in names (rule 11):
1. **Safe to delete** (you will do it)
2. **Needs the user's action** (admin command, system setting, the app's own cleanup)
3. **User's call** (personal data, chat data, portable apps, unclear origin)
4. **Don't touch** (system, recovery partition, toolchains in use, the user's "keep" list)

Use these fixed names in the user's language, so reports and notes from different sessions line up (Chinese below; for other languages pick one wording and keep it):

| Report group | 中文 | Notes heading | 中文 |
|---|---|---|---|
| (3d) Possible security issue | 疑似安全问题 | Keep | 保留 |
| Safe to delete | 可以直接删 | Identified, awaiting decision | 已查明可清理（等用户决定） |
| Needs the user's action | 需要你操作 | Known facts | 已知情况 |
| User's call | 你来决定 | User to-do | 待用户操作 |
| Don't touch | 不要动 | Done / Free space | 已处理 / 剩余空间记录 |

Point the user to Windows settings by the labels they see on screen (Chinese Windows: 设置 → 应用 → 安装的应用, not "Settings > Apps"); `references/known-locations.md` has the common paths in English and Chinese.

### 5. Delete and verify
- After confirmation, write the paths to a list file (`-ListFile`; more reliable than `-Paths a,b`) and run `Remove-Paths.ps1`; system paths via the elevated template. On "Access denied" retry once elevated.
- An installer verdict needs more than a name: use `Test-Installer.ps1` and give the evidence.
- Package caches via their own commands (`npm cache clean --force`, `pip cache purge`, `uv cache clean`, `conda clean --all` - the latter often finds nothing because conda `pkgs` are hard-linked into environments; never report the folder size as freeable).
- Report successes, failures, freed space and current free space. Files locked by a running program (often DLLs): stop the program or reboot, then retry.
- If old data may matter (an old chat-app data folder), compare old and new locations first and copy whatever exists only in the old one to a safe place before deleting.

### 6. Update the notes
Before finishing, write what you learned to `<ScanDir>\disk-notes.md` (append or edit, with dates; in the user's language). Record decisions and facts, not the process:
- **Keep**: paths the user wants kept, and why; files that are the only copy.
- **Identified, awaiting decision**: everything you found but the user has not decided on - path, size, evidence. Move it to "Done" when deleted, to "Keep" when the user says keep.
- **Known facts**: e.g. where user folders are redirected, programs installed into a drive root, folders that look regenerable but contain user data.
- **User to-do**, **Done**, **free space per drive** at the end of this session.

Use the fixed headings from the table in section 4 (in the user's language), and keep the headings an existing notes file already uses. Example in English:

```markdown
## Keep
- `D:\OldChatApp Files` - old chat-app data, may hold history the new version lacks (2026-01-15)
## Identified, awaiting decision
| Size | Path | Evidence / how | Found |
|---|---|---|---|
| 1.3GB | `D:\Users\me\Videos\RepairTool\recovered.h264` | repair tool intermediate; delete once the repaired video is saved | 2026-01-15 |
## Known facts
- `D:\` root has WinRAR installed directly in it; its exe/dll files are the program (2026-01-15)
## User to-do
- Disable hibernation: admin terminal `powercfg /h off`, frees ~6 GB on C: (2026-01-15, pending)
## Free space
- 2026-01-15: C 14.1GB, D 139.6GB
```

## Things to clarify when reporting
- Users often say "memory" when they mean disk space; correct it once.
- Free space drifting by a few hundred MB is normal (logs, shader caches, system databases); `Find-OldFiles.ps1 -RecentHours 1` shows what was just written.
- Images, videos and files inside chat apps are conversation content, not cache; once deleted they usually cannot be re-downloaded (servers keep them for a limited time).
