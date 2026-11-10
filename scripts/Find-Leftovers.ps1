<#
.SYNOPSIS
  Find app folders that do not belong to any installed program (likely leftovers), on any drive.
.DESCRIPTION
  System drive: direct subfolders of Program Files, Program Files (x86), ProgramData and the user's
  AppData\Local, Local\Programs, Roaming, LocalLow.
  Other drives: direct subfolders of X:\Program Files, X:\Program Files (x86), and top-level X:\ folders
  that LOOK LIKE PROGRAM FOLDERS (an .exe directly inside, or one level down). Top-level folders without
  executables are treated as user data and never listed.
  Sizes come from the latest WizTree folders scan of each drive (Invoke-WizTreeScan.ps1 -Drive X).
  Each folder is checked against uninstall registry entries, Start Menu shortcuts (name+target) and
  running process paths. Status values:
    installed       - matches an installed program (hidden unless -All)
    running         - a running process lives under it
    tool-data       - data of a developer tool (npm, uv, ...), not a leftover
    startmenu       - has a Start Menu shortcut but no uninstall entry
    unknown-recent  - no match, but something inside was written in the last -RecentDays days
    likely-leftover - no match and nothing written for -RecentDays days
  Matching is by name, so always sanity-check the result before deleting.
.EXAMPLE
  .\Find-Leftovers.ps1                 # all fixed drives that have a saved scan
  .\Find-Leftovers.ps1 -Drives D -MinMB 50
#>
param(
  [string[]]$Drives,
  [double]$MinMB = 20,
  [int]$RecentDays = 60,
  [switch]$All
)
. "$PSScriptRoot\WizTreeCsv.ps1"
$sysDrive = $env:SystemDrive.Substring(0,1).ToUpper()
if (-not $Drives) { $Drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' -and $_.Used -gt 0 } | ForEach-Object Name }
# "powershell -File x.ps1 -Drives C,D" passes ONE string "C,D": split it, or D: is silently skipped.
$Drives = @($Drives | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ } | ForEach-Object { $_.Substring(0,1).ToUpper() } | Sort-Object -Unique)

function Norm([string]$s) { if (-not $s) { return '' }; return ($s.ToLower() -replace '[\s\-_\.\(\)]','') }

$skip = @('microsoft','windows','packages','temp','common files','windowsapps','windows defender','windows nt','windows mail',
  'windows media player','windows photo viewer','windows portable devices','windows security','windows sidebar','windowspowershell',
  'internet explorer','modifiablewindowsapps','reference assemblies','msbuild','dotnet','packagemanagement','package cache',
  'microsoft.net','uninstall information','usoshared','usoprivate','ssh','programs','crashdumps','d3dscache','connecteddevicesplatform',
  'peerdistrepub','publishers','virtualstore','placeholdertilelogofolder','history','comms','regid.1991-06.com.microsoft',
  'desktop','documents','start menu','templates','application data','microsoft onedrive','windows kits','microsoft sdks','iconcache',
  '$recycle.bin','system volume information','recovery','wiztreescans','huaweimovedata','users','program files','program files (x86)',
  'programdata','perflogs','config.msi','$windows.~bt','$windows.~ws','msocache','onedrivetemp')
$toolData = @('uv','npm','pnpm','yarn','pip','pipx','nltk_data','ms-playwright','ms-playwright-go','huggingface','conda','cargo',
  'go-build','node-gyp','nvm','deno','bun','poetry','jupyter','ipython','gradle','maven','nuget','typescript')

# --- evidence (shared by all drives) ---
$keys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
$apps = Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }
$appText = Norm (($apps | ForEach-Object { "$($_.DisplayName)|$($_.Publisher)|$($_.InstallLocation)|$($_.DisplayIcon)|$($_.UninstallString)" }) -join '||')
$sh = New-Object -ComObject WScript.Shell
$lnks = Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Recurse -Filter *.lnk -ErrorAction SilentlyContinue
# Only shortcuts whose target still exists count as "installed" evidence; dead ones are leftovers themselves.
$deadLnks = New-Object System.Collections.Generic.List[object]
$liveLnk = foreach ($l in $lnks) {
  $t = ''; try { $t = $sh.CreateShortcut($l.FullName).TargetPath } catch {}
  if ($t -and $t -match '^[A-Za-z]:\\' -and -not (Test-Path -LiteralPath $t)) { $deadLnks.Add([pscustomobject]@{ Shortcut = $l.FullName; MissingTarget = $t }); continue }
  "$($l.BaseName)|$t"
}
$lnkText = Norm ($liveLnk -join '||')
$procPaths = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Path } catch {} } | Where-Object { $_ } | ForEach-Object { $_.ToLower() })

function Test-LooksLikeProgram([string]$dir) {
  # Non-recursive: .exe directly inside, or inside one of the first 40 subfolders.
  if (Get-ChildItem -LiteralPath $dir -Filter *.exe -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1) { return $true }
  foreach ($sub in (Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue | Select-Object -First 40)) {
    if (Get-ChildItem -LiteralPath $sub.FullName -Filter *.exe -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1) { return $true }
  }
  return $false
}

$sortable = [regex]'^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}$'
$now = Get-Date
$res = New-Object System.Collections.Generic.List[object]
foreach ($dv in $Drives) {
  try { $Csv = Get-LatestScan -Drive $dv -Mode 'folders' } catch { Write-Host "SKIP ${dv}: no folders scan saved (run Invoke-WizTreeScan.ps1 -Drive $dv)"; continue }
  Write-Host ("Scan {0}: {1}" -f $dv, (Split-Path $Csv -Leaf))
  $topLevel = $null
  if ($dv -eq $sysDrive) {
    $roots = @("$env:ProgramFiles\", "${env:ProgramFiles(x86)}\", "$env:ProgramData\",
               "$env:LOCALAPPDATA\", "$env:LOCALAPPDATA\Programs\", "$env:APPDATA\", "$env:USERPROFILE\AppData\LocalLow\")
  } else {
    $topLevel = "${dv}:\"
    $roots = @("${dv}:\Program Files\", "${dv}:\Program Files (x86)\", $topLevel)
  }
  $rows = @(Read-WizTreeCsv $Csv (New-ChildFolderRegex $roots) ($MinMB * 1MB))

  # newest timestamp of any subfolder (a folder's own timestamp does not change when files deep inside change)
  $latest = [WtCsv]::LatestUnder($Csv, [string[]]$roots)   # C#: one pass over the scan

  foreach ($r in $rows) {
    $name = Split-Path $r.Path.TrimEnd('\') -Leaf
    if ($skip -contains $name.ToLower()) { continue }
    $isTop = $topLevel -and (($r.Path.TrimEnd('\') -replace '[^\\]+$','') -ieq $topLevel)
    if ($isTop -and -not (Test-LooksLikeProgram $r.Path)) { continue }   # user data, not a program folder
    $n = Norm $name
    $pathL = $r.Path.ToLower()
    $last = if ($latest.ContainsKey($pathL)) { $latest[$pathL] } else { $r.Modified }
    $status =
      if ($n.Length -ge 3 -and ($appText.Contains($n) -or $appText.Contains((Norm $r.Path.TrimEnd('\'))))) { 'installed' }
      elseif ($procPaths | Where-Object { $_.StartsWith($pathL) } | Select-Object -First 1) { 'running' }
      elseif ($toolData -contains $name.ToLower()) { 'tool-data' }
      elseif ($n.Length -ge 3 -and $lnkText.Contains($n)) { 'startmenu' }
      else {
        $d = ConvertTo-ScanDate $last
        if ($d -and ($now - $d).TotalDays -le $RecentDays) { 'unknown-recent' } else { 'likely-leftover' }
      }
    if (-not $All -and $status -eq 'installed') { continue }
    $res.Add([pscustomobject]@{ MB = [math]::Round($r.Alloc/1MB); LastWrite = $last.Split(' ')[0]; Status = $status; Path = $r.Path })
  }
}
$res | Sort-Object @{e={ @{ 'likely-leftover'=0; 'unknown-recent'=1; 'startmenu'=2; 'tool-data'=3; 'running'=4; 'installed'=5 }[$_.Status] }}, @{e='MB';Descending=$true} |
  Format-Table MB, LastWrite, Status, Path -AutoSize | Out-String -Width 300
Write-Host 'LastWrite = newest timestamp of any subfolder in the scan. likely-leftover = no install/startmenu/process match and no writes for -RecentDays days.'
Write-Host 'On non-system drives only top-level folders containing .exe files are considered; folders without executables are treated as user data.'
Write-Host 'Name matching is heuristic: verify each item (installed under another name? portable app? game library? user data?) before deleting.'

if ($deadLnks.Count) {
  Write-Host "`n== Start Menu shortcuts whose target no longer exists (leftovers; check names with odd/invisible characters too)"
  $deadLnks | Format-Table -AutoSize | Out-String -Width 300
}

# Startup (Run / RunOnce) entries whose program is gone: the app was deleted or uninstalled badly, Windows
# still tries to start it at every logon (and Settings > Apps > Startup lists a nameless entry).
$deadRun = foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
                           'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
                           'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
  $props = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
  if (-not $props) { continue }
  foreach ($pr in $props.PSObject.Properties | Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$' }) {
    $cmd = [Environment]::ExpandEnvironmentVariables([string]$pr.Value).Trim()
    $exe = if ($cmd -match '^"([^"]+)"') { $matches[1] } elseif ($cmd -match '^(.+?\.(exe|bat|cmd|vbs|ps1))(\s|$)') { $matches[1] } else { ($cmd -split '\s+')[0] }
    # bare names (rundll32, ctfmon) resolve through PATH: not checked
    if ([IO.Path]::IsPathRooted($exe) -and -not (Test-Path -LiteralPath $exe)) {
      [pscustomobject]@{ Key = ($k -replace '^HK(CU|LM):\\Software\\(WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\', 'HK$1 $2'); Name = $pr.Name; Command = $cmd }
    }
  }
}
if ($deadRun) {
  Write-Host "`n== Startup (Run) entries whose program no longer exists (leftovers; HKLM needs admin to remove)"
  $deadRun | Format-Table -AutoSize -Wrap | Out-String -Width 300
}

# Loose files in the ROOT of non-system drives: the folder checks above cannot see them
# (seen: GUID-named .tmp copies of a failed MSI install, an old portable app unpacked straight into D:\).
foreach ($dv in $Drives) {
  if ($dv -eq $sysDrive -or -not (Test-Path "${dv}:\")) { continue }
  $files = @(Get-ChildItem -LiteralPath "${dv}:\" -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Length -ge 10MB -and $_.Name -notmatch '^(pagefile|swapfile|hiberfil)\.sys$' })
  if (-not $files) { continue }
  Write-Host ("`n== Loose files >= 10 MB in {0}:\ (not covered by the folder checks)" -f $dv)
  $files | Sort-Object Length -Descending | Select-Object @{n='MB';e={[math]::Round($_.Length/1MB)}}, @{n='Date';e={$_.LastWriteTime.ToString('yyyy-MM-dd')}},
    @{n='Hint';e={ if ($_.Name -match '^[0-9a-f]{8}-[0-9a-f]{4}-.*\.tmp$') { 'GUID .tmp: often a failed MSI install copy; read its summary (WindowsInstaller COM) before deleting' }
                   elseif ($_.Extension -match '^\.(exe|msi)$') { 'run Test-Installer.ps1 -Folder on this root' }
                   elseif ($_.Extension -match '^\.(zip|rar|7z)$') { 'archive: is it already extracted somewhere?' } else { '' } }}, Name |
    Format-Table -AutoSize | Out-String -Width 300
}
