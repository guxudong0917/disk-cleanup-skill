# Known locations

Confirm sizes from the snapshot first, then judge with these tables. `<U>` = `C:\Users\<user>`.
Apps common in mainland China (chat apps, cloud drives, OEM PC managers, bundleware) are in `china-apps.md`.

## 1. Regenerable caches (rebuilt automatically; usually safe)

| Location | What | How |
|---|---|---|
| `<U>\AppData\Local\npm-cache` | npm download cache | `npm cache clean --force` |
| `<U>\AppData\Local\pip\cache` | pip cache | `pip cache purge` |
| `<U>\AppData\Local\uv\cache` | uv cache | `uv cache clean` |
| `<U>\AppData\Local\pnpm`, `Yarn\Cache` | other package-manager caches | the tool's own clean command |
| `<U>\AppData\Local\ms-playwright`, `ms-playwright-go` | browsers downloaded by Playwright | delete if no browser automation; re-downloaded on demand |
| `<U>\.cache\huggingface` | model cache | ask whether those models are still used |
| `<U>\.cache\<tool>-runtimes\*.previous-*` | previous runtime versions kept by an AI coding tool | delete `previous-*`, keep the current one |
| `<U>\.vscode\extensions\.<guid>` (hidden, dot-prefixed) | failed or old extension install | check its `package.json` is an older version, then delete |
| `<U>\AppData\Local\nvm\v*` | Node versions installed by nvm | `nvm list`, then `nvm uninstall <ver>` for unused ones |
| `<U>\AppData\Local\Temp` | temp files | only files older than 7 days; the current session's temp folder lives here too |
| `<U>\AppData\LocalLow\Intel\ShaderCache`, `Local\D3DSCache` | GPU shader caches | grow back; rarely worth it |
| `C:\Windows\SoftwareDistribution\Download` | Windows Update downloads | Disk Cleanup → Clean up system files |
| `<U>\AppData\Local\<app>-updater\installer.exe`, `...\update\*.exe` | installers downloaded by an installed app's updater | safe; re-downloaded on the next update |

**Browser caches (check every drive; browsers can be installed on D:)**: under `...\Chrome\User Data\<profile>\` and `...\Microsoft\Edge\User Data\<profile>\`: `Cache`, `Code Cache`, `GPUCache`, `Service Worker\CacheStorage`, `Service Worker\ScriptCache`. Every profile (Default, Profile 1, ...) has its own; together often 1-3 GB. Query the snapshot, do not recurse:

```powershell
. '<skill>\scripts\WizTreeCsv.ps1'
$rx = [regex]::new('^"[A-Z]:\\[^"]*\\User Data\\[^\\"]+\\(Cache|Code Cache|GPUCache|Service Worker\\CacheStorage|Service Worker\\ScriptCache)\\",', 'IgnoreCase')
$rows = Read-WizTreeCsv (Get-LatestScan -Drive D -Mode folders) $rx
"{0:N2} GiB" -f (($rows | Measure-Object Alloc -Sum).Sum / 1GB); $rows | Sort-Object Alloc -Descending | Select-Object -First 10 @{n='MB';e={[math]::Round($_.Alloc/1MB)}}, Path
```
(Default system-drive locations: `<U>\AppData\Local\Google\Chrome\User Data`, `...\Microsoft\Edge\User Data` - use `-Drive C`.) Report under "needs your action": browser settings → clear browsing data → only "cached images and files", in every profile. Do not delete the folders (breaks a running browser, risks sign-in data).

**Recycle Bin**: `X:\$RECYCLE.BIN\<SID>` per account. Use `Get-FolderSizes.ps1 -Path 'X:\$RECYCLE.BIN'` for the real size. **Do not count it with `Shell.Application`**: that only shows the current account's items, not other accounts' or a previous Windows install's. Emptying: the current account's bin via the Recycle Bin UI (or `Clear-RecycleBin -DriveLetter D`); other SIDs' folders need admin - tell the user their size and ask first.

**Virtual disks**: `*.vhdx` (WSL `ext4.vhdx`, Docker Desktop, Hyper-V) grow but never shrink by themselves. Check real usage inside (`wsl -d <distro> df -h /`); if much smaller, suggest compacting (`wsl --shutdown`, then `diskpart` → `compact vdisk`, or `wsl --manage <distro> --set-sparse true` on recent WSL). Never delete the vhdx: it is the whole Linux system.

**Other common findings (often on personal-data drives)**
| Location / pattern | What | How |
|---|---|---|
| `Anaconda\pkgs`, `Miniconda\pkgs` | conda package cache; **mostly hard-linked into environments**, deleting saves nothing | at most suggest `conda clean --all`; never report the folder size as freeable - it often finds nothing |
| `.pnpm-store`, `.pnpm-store-*` | pnpm content store | `pnpm store prune`; **never delete part of it** (corrupts the store) |
| phone-transfer / backup folders (`...\Backup\...\Camera`) | backups of photos and videos from a phone | personal data; ask whether the phone/gallery still has them before suggesting move or delete |
| `recovered.h264`, `recovered.aac` in a video-repair tool's folder | intermediate raw streams of a repair | removable once the repaired video is saved; ask |
| GUID-named `.tmp` files in a drive root (same day, tens of MB) | often copies of a failed MSI install (e.g. a game launcher) | read title/author via `WindowsInstaller.Installer` COM `SummaryInformation`; removable if that software never got installed |
| `packages\`, `resources\` in a drive root with `AAM`/`ACC`/`ADC` or "readme"/"disclaimer" TXT files | files unpacked by a repackaged/cracked installer (often Adobe) | removable if that software is gone |
| a whole program unpacked into a drive root (many dll + exe + `uninstall\uninstall.log`) | portable or old copy of a program | compare its version with the installed one; remove an old copy **file by file from `uninstall.log`** - never wipe the root (other programs may live there too) |
| `A.rar` / `A.zip` next to folder `A\` | already-extracted archive | uncompressed total = folder size → archive redundant; folder bigger → edited after extraction, the archive is the original - ask |

**Looks like cache, but is not:**
- `<U>\AppData\Roaming\uv`: Pythons and tools installed by uv (`python\`, `tools\`); deleting breaks them.
- `<U>\AppData\Roaming\npm\node_modules`: globally installed npm CLIs, not cache.
- A browser's whole `User Data` folder: bookmarks, passwords, sessions. Clear cache inside the browser only.
- `node_modules\npm`, `node_modules\corepack` in a drive root next to `node.exe` / `npm.cmd`: Node.js installed into that root; deleting breaks npm.
- `.venv` is not always only an environment: people park outputs and reports inside it. Only `Lib`, `Scripts`, `Include`, `share` are the environment.
- Images, videos and files in chat apps: conversation content, usually unrecoverable once deleted.

## 2. System-level items (system tools only)

| Item | How | Cost |
|---|---|---|
| `C:\hiberfil.sys` (≈ 40-75 % of RAM) | admin terminal `powercfg /h off`; or `powercfg /h /type reduced` to keep Fast Startup | no hibernate / Fast Startup; Sleep unaffected |
| `C:\pagefile.sys` | usually leave it | shrinking can crash programs when RAM runs out |
| `C:\Windows\WinSxS` | `Dism /Online /Cleanup-Image /AnalyzeComponentStore`, then `/StartComponentCleanup` (admin) | Explorer's size counts hard links; trust DISM's "Actual Size" |
| Windows Update leftovers, old driver packages | Disk Cleanup (cleanmgr) → Clean up system files | none |
| System restore points | System Properties → System Protection → Configure | lose restore points |
| `C:\Program Files\WindowsApps\<App>_<newer version>` next to the running older version | a downloaded Store/MSIX update waiting for the app to restart | restart the app; Windows removes the old version |

**System temp folders and crash dumps** (often months old, so "recent writes" never shows them):
| Location | What | How |
|---|---|---|
| `C:\Windows\ServiceProfiles\LocalService\AppData\Local\Temp`, `...\NetworkService\AppData\Local\Temp` | temp folders of system services; can hold GB-sized `.dmp` | `Find-OldFiles -Drive C` crash-dump section; admin to delete |
| `C:\Windows\System32\config\systemprofile\AppData\Local\CrashDumps` | dumps of services running as SYSTEM | deletable; admin |
| `C:\Windows\Temp` | system temp | files older than 7 days, or Disk Cleanup |
| `C:\Windows\LiveKernelReports\*.dmp`, `C:\Windows\Minidump`, `C:\Windows\MEMORY.DMP` | kernel / blue-screen dumps | deletable unless a BSOD is being investigated (Disk Cleanup → system error memory dump files) |
| `%LOCALAPPDATA%\CrashDumps`, `%APPDATA%\<app>\...\Dump` | application crash dumps | deletable |
| `%APPDATA%\Code\Crashpad`, `CachedData`, `CachedExtensionVSIXs` | VS Code crash reports, compile cache, extension package cache | delete with VS Code closed; leave `WebStorage` (extension data) |
| `C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache` | Windows Update Delivery Optimization cache | Settings → System → Storage → Temporary files → Delivery Optimization Files (设置 → 系统 → 存储 → 临时文件 → 传递优化文件) |

Identifying a dump: a minidump starts with `MDMP`; its module-list stream names the crashed process first. A header of zeros means the dump was never finished (no debugger can open it) - the strings inside may still hint at the source (font names → font cache service).

## 3. Don't touch

- `C:\Windows`, `System32`, `WinSxS` (by hand), `C:\Windows\Installer` (needed to repair/uninstall MSI software)
- `C:\Recovery` (OEM factory image), `$WinREAgent`, `System Volume Information`, `$Recycle.Bin` (by hand), `$Extend`, `Config.Msi`
- `C:\Program Files\WindowsApps`: Store apps - uninstall via Settings > Apps only
- `C:\Documents and Settings`, `<U>\Application Data` etc.: compatibility junctions, take no space
- Toolchain locations such as `C:\Program Files\nodejs` or an nvm symlink folder
- `ProgramData\Intel Package Cache {...}`: needed to repair/uninstall Intel drivers
- `$SysReset`: reset logs, protected; not worth forcing
- Root folders `PerfLogs`, `inetpub`, `Intel`, `OneDriveTemp`: created by Windows/drivers, come back
- Visual C++ redistributables in Settings > Apps (many versions x86/x64 are normal; each serves different programs)

## 4. Use the app's own cleanup

| App | Location | Where |
|---|---|---|
| Edge / Chrome | `<U>\AppData\Local\Microsoft\Edge\User Data` etc. | settings → clear browsing data (cache only) |
| VS Code | `Roaming\Code\Cache`, `CachedData`, `WebStorage` | close VS Code, then delete Cache/CachedData; WebStorage is extension data - careful |
| Chat apps, cloud drives, OEM PC managers | see `china-apps.md` for common ones | the app's storage settings |

## 5. Regenerable project artifacts (basis of Find-ProjectArtifacts)

| Project | Detected by | Deletable (regenerated) | Rebuild | Never delete |
|---|---|---|---|---|
| Unity | `Assets` + `ProjectSettings\ProjectVersion.txt` | `Library`, `Temp`, `Logs`, `obj`, `Build(s)` | open in Unity (first open takes minutes) | `Assets`, `Packages`, `ProjectSettings` |
| Unreal source project | `*.uproject` + `Content` + `Config` | `Intermediate`, `Saved`, `DerivedDataCache`, `Binaries` | open the .uproject / rebuild | `Content`, `Config`, `Source`, `.uproject`; `Engine\Binaries` of a **packaged build** |
| Node | `node_modules` + `package.json` | `node_modules`, `.next`, `.nuxt`, `.parcel-cache` | `npm install` / `pnpm install` | `package.json`, lock files |
| Python | `.venv`/`venv` with `Scripts` | `.venv` (only `Lib`/`Scripts`/`Include` if it holds other data), `__pycache__`, `.pytest_cache`, `.mypy_cache` | `python -m venv .venv` + `pip install -r requirements.txt` (**re-downloads**) | code, `requirements.txt` / `pyproject.toml` |
| Gradle / Android | `.gradle` or `app\build` | `.gradle`, `build`, `app\build` | rebuild | the rest |
| Visual Studio C/C++ | `.vs` | `.vs` (IntelliSense DB), `x64`, `Debug`, `Release`, `ipch` | rebuild the solution | `.sln`, `.vcxproj`, sources |
| Premiere / After Effects | preview and cache folders | `Adobe Premiere Pro Video/Audio Previews`, `Media Cache Files`, `Media Cache`, `Peak Files`, `Analyzer Cache Files` | rebuilt when the project opens | footage, `.prproj` (the project itself, unless the user no longer uses the editor) |

"Cold" = the newest timestamp in the whole subtree (not the folder's own timestamp) is old, **and** the top-level work folder it belongs to is cold too; otherwise it may be an untouched module of an active project.

## 6. Leftover patterns

- **Program folder deleted by hand instead of uninstalled** → the uninstall entry remains ("cannot find ... uninstall.exe" in Settings) and AppData still holds its data. Use `Find-BrokenUninstallEntries.ps1` + `Find-Leftovers.ps1`.
- **Bundled companion components** survive the main app (security/protection services, game anti-cheat folders, silently downloaded installers of bundleware). Self-protecting services often defeat their own uninstaller: as admin `sc config <svc> start= disabled`, `sc delete <svc>`, stop the process, delete the folder; locked DLLs after a reboot.
- **Auto-downloaded upgrade packages**: download-manager `...\Download\*.exe`, `*-updater\installer.exe`, `AppData\Roaming\<x>\*.exe`.
- **Junk folders created in a drive root by apps**: e.g. `C:\AppData`, `C:\Downloads`, `C:\db`, `C:\cef_cache`, `C:\MyDrivers`, `C:\Recycler` (old-style recycle bin). Confirm empty or orphaned first.
- **Dead Start Menu shortcuts**: `.lnk` whose target exe is gone (listed by `Find-Leftovers.ps1`).
- **Dead startup entries**: `HKCU`/`HKLM ...\CurrentVersion\Run` values pointing at a deleted exe (listed by `Find-Leftovers.ps1`). Back up the value first (`Get-ItemProperty` to a text file), then `Remove-ItemProperty`.
- **Registration of portable / repacked apps**: repacks often write an uninstall entry and a Run entry pointing into the portable folder. Deleting the folder alone leaves both behind.
- **Update backups inside an app's folder**: `*.old`, `*.bak`, `*_old`, `backup\`, or older `<version>\` folders kept by self-updaters.
- **Discontinued Store apps**: still installed after the service shut down; uninstall in Settings.

## 7. Windows UI paths (English / 简体中文)

Name settings the way the user sees them. Windows 11:

| What | English | 简体中文 |
|---|---|---|
| Uninstall an app | Settings → Apps → Installed apps | 设置 → 应用 → 安装的应用 |
| Startup apps | Settings → Apps → Startup | 设置 → 应用 → 启动 |
| Storage overview | Settings → System → Storage | 设置 → 系统 → 存储 |
| Temporary files (Windows Update Cleanup, Delivery Optimization Files) | Storage → Temporary files | 存储 → 临时文件（Windows 更新清理、传递优化文件） |
| Storage Sense | Storage → Storage Sense | 存储 → 存储感知 |
| Cleanup recommendations | Storage → Cleanup recommendations | 存储 → 清理建议 |
| Classic Disk Cleanup | Disk Cleanup → Clean up system files | 磁盘清理 → 清理系统文件 |
| Page file | System Properties → Advanced → Performance → Settings → Advanced → Virtual memory | 系统属性 → 高级 → 性能 → 设置 → 高级 → 虚拟内存 |
| Restore points | System Properties → System Protection → Configure | 系统属性 → 系统保护 → 配置 |
| Defender history | Windows Security → Virus & threat protection → Protection history | Windows 安全中心 → 病毒和威胁防护 → 保护历史记录 |
| Offline scan | Virus & threat protection → Scan options → Microsoft Defender Offline scan | 病毒和威胁防护 → 扫描选项 → Microsoft Defender 脱机版扫描 |
| Scheduled tasks / services | Task Scheduler / Services | 任务计划程序 / 服务 |
| Recycle Bin | Recycle Bin → Empty Recycle Bin | 回收站 → 清空回收站 |

Windows 10: "Apps & features" = "应用和功能"; Storage is under Settings → System as well.
