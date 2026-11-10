<#
.SYNOPSIS
  Report the user's own work folders and projects on a drive: how big, when last touched, and how much of
  each project is a REGENERABLE artifact (node_modules, .venv, Unity Library, Unreal Intermediate, Gradle
  build, VS .vs/x64, Premiere media caches...). Also flags similar-named sibling folders and packaged builds.
  Read-only. Uses the latest WizTree folders scan of the drive (no disk walk).
.DESCRIPTION
  Scope (default): the user's Desktop/Documents/Pictures/Videos/Downloads (wherever redirected) that live on
  -Drive, plus, on a non-system drive, top-level folders that are not installed programs.
  Project detection by folder signature (verified with a cheap non-recursive check where noted):
    Unity        Assets + ProjectSettings\ProjectVersion.txt     -> Library, Temp, Logs, obj, Build(s)
    Unreal       *.uproject file + Content + Config               -> Intermediate, Saved, DerivedDataCache, Binaries
    Node         node_modules                                     -> node_modules, .next, .nuxt, .parcel-cache
    Python       .venv|venv with Scripts\                         -> venv, __pycache__, .pytest_cache, .mypy_cache  (re-download needed!)
    Gradle       .gradle or app\build                             -> .gradle, build, app\build
    VisualStudio .vs                                              -> .vs, x64, Debug, Release, ipch
    MediaCache   Premiere/After Effects cache folders             -> previews, Media Cache Files, Peak Files
  Status per project:
    cold                  - nothing inside written for -ColdDays days and its top-level work folder is cold too
    cold-in-active-folder - project is cold but its work folder was touched recently (ask first)
    active                - touched within -ColdDays days (do not clean)
  Outputs: console tables, a CSV report with an empty Decision column for the user, and optionally
  -DeleteList: a text file with the artifact paths of 'cold' projects, ready for
  Remove-Paths.ps1 -ListFile <it> -Recycle never   (artifacts are regenerable, recycling them is pointless).
.EXAMPLE
  .\Find-ProjectArtifacts.ps1 -Drive D -DeleteList "$env:TEMP\regen.txt"
#>
param(
  [string]$Drive = 'D',
  [string]$Csv,
  [string[]]$Roots,
  [int]$ColdDays = 60,
  [string]$OutCsv,
  [string]$DeleteList,
  [switch]$NoReport   # read-only analysis: do not write the CSV report
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\WizTreeCsv.ps1"
$Drive = $Drive.Substring(0,1).ToUpper()
if (-not $Csv) { $Csv = Get-LatestScan -Drive $Drive -Mode 'folders' }
if (-not $OutCsv -and -not $NoReport) { $OutCsv = Join-Path (Split-Path $Csv) ("{0}_projects-report_{1:yyyyMMdd-HHmm}.csv" -f $Drive, (Get-Date)) }

# WtTree / WtNode come from WizTreeCsv.ps1 (shared C#).
$sample = Get-Content -LiteralPath $Csv -TotalCount 3 | Select-Object -Last 1
if ($sample -notmatch ',\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2},') { Write-Host 'WARN: scan dates are not yyyy/MM/dd HH:mm:ss; "newest write" comparisons may be off.' }
$t = Get-Date
[WtTree]::Load($Csv)
$Nodes = [WtTree]::Nodes
Write-Host ("Scan: {0}  ({1} folders, loaded in {2:N1}s)" -f (Split-Path $Csv -Leaf), $Nodes.Count, ((Get-Date) - $t).TotalSeconds)
function Kids([string]$p) { if ([WtTree]::Kids.ContainsKey($p)) { [WtTree]::Kids[$p] } }
function Has([string]$p, [string]$child) { return $Nodes.ContainsKey($p + $child + '\') }
function Sz([string]$p) { if ($Nodes.ContainsKey($p)) { return $Nodes[$p].Alloc } else { return 0 } }
$cutStr = (Get-Date).AddDays(-$ColdDays).ToString('yyyy/MM/dd HH:mm:ss')
function IsCold([string]$maxMod) { return [string]::CompareOrdinal($maxMod, $cutStr) -lt 0 }

# ---- scope ----
if (-not $Roots) {
  $Roots = @('Desktop','MyDocuments','MyPictures','MyVideos') | ForEach-Object { [Environment]::GetFolderPath($_) }
  $Roots += (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads')
  $Roots = @($Roots | Where-Object { $_ -and $_.Substring(0,1).ToUpper() -eq $Drive } | ForEach-Object { $_.TrimEnd('\') + '\' })
  if ($Drive -ne $env:SystemDrive.Substring(0,1).ToUpper()) {
    $apps = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object DisplayName
    $appText = (($apps | ForEach-Object { "$($_.InstallLocation)|$($_.DisplayIcon)|$($_.UninstallString)" }) -join '|').ToLower()
    # node_modules at a drive root = a Node.js installed into that root (node.exe, npm.cmd next to it), not a user project
    $skipRoot = @('program files','program files (x86)','wiztreescans','$recycle.bin','system volume information','msocache','recovery','users','windows','.pnpm-store','pnpm-store','node_modules')
    $procPaths = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Path } catch {} } | Where-Object { $_ } | ForEach-Object { $_.ToLower() })
    $appText += '|' + ($procPaths -join '|')   # a running program lives there => it is an install folder, not user work
    foreach ($n in (Kids "${Drive}:\")) {
      $leaf = $n.Path.TrimEnd('\').Substring(3)
      if ($skipRoot -contains $leaf.ToLower()) { continue }
      if ($appText.Contains($n.Path.TrimEnd('\').ToLower())) { continue }        # an installed program lives here
      $np = $n.Path
      if (@($Roots | Where-Object { $_.StartsWith($np, [StringComparison]::OrdinalIgnoreCase) }).Count) { continue }   # holds redirected user folders, already in scope
      $Roots += $np
    }
  }
}
$Roots = @($Roots | Where-Object { $Nodes.ContainsKey($_) } | Sort-Object -Unique)
Write-Host ("Scope: {0} root folders" -f $Roots.Count)
function WorkFolder([string]$p) {   # first-level child of the scope root that contains $p
  foreach ($r in $Roots) { if ($p.StartsWith($r, 'OrdinalIgnoreCase') -and $p.Length -gt $r.Length) { $i = $p.IndexOf('\', $r.Length); return $p.Substring(0, $i + 1) } }
  return $p
}

# ---- detect projects ----
$regenNames = @{
  'Unity'        = @('Library','Temp','Logs','obj','Build','Builds');
  'Unreal'       = @('Intermediate','Saved','DerivedDataCache','Binaries');
  'Node'         = @('node_modules','.next','.nuxt','.parcel-cache');
  'Python'       = @('.venv','venv','__pycache__','.pytest_cache','.mypy_cache');
  'Gradle'       = @('.gradle','build','app\build');
  'VisualStudio' = @('.vs','x64','Debug','Release','ipch');
  'MediaCache'   = @('Adobe Premiere Pro Video Previews','Adobe Premiere Pro Audio Previews','Media Cache Files','Media Cache','Peak Files','Analyzer Cache Files','Adobe After Effects Disk Cache');
}
$markers = [string[]]@('Assets','Content','node_modules','.venv','venv','.gradle','app','.vs','Adobe Premiere Pro Video Previews','Adobe Premiere Pro Audio Previews','Media Cache Files','Peak Files')
$walked = [WtTree]::Candidates([string[]]$Roots, $markers)
$found = New-Object System.Collections.Generic.List[object]
$venvParts = @('Lib','Scripts','Include','share','lib64','bin','etc','DLLs','Tools')
foreach ($n in $walked) {
  $p = $n.Path; $type = $null; $note = ''
  # A package inside node_modules (e.g. D:\node_modules\npm\ of a Node install) is never a user project.
  if ($p -match '(?i)\\node_modules\\') { continue }
  # Folder that is itself a program install (node.exe / python.exe right inside) is not a project either.
  if ((Test-Path -LiteralPath ($p + 'node.exe')) -or (Test-Path -LiteralPath ($p + 'python.exe'))) { continue }
  if ((Has $p 'Assets') -and (Has $p 'ProjectSettings') -and (Test-Path -LiteralPath ($p + 'ProjectSettings\ProjectVersion.txt'))) { $type = 'Unity' }
  elseif ((Has $p 'Content') -and (Has $p 'Config') -and (Get-ChildItem -LiteralPath $p -Filter *.uproject -File -ErrorAction SilentlyContinue | Select-Object -First 1)) { $type = 'Unreal' }
  elseif ((Has $p 'node_modules') -and (Test-Path -LiteralPath ($p + 'package.json'))) { $type = 'Node' }
  elseif (((Has $p '.venv') -and (Has ($p + '.venv\') 'Scripts')) -or ((Has $p 'venv') -and (Has ($p + 'venv\') 'Scripts'))) { $type = 'Python' }
  elseif ((Has $p '.gradle') -or ((Has $p 'app') -and (Has ($p + 'app\') 'build'))) { $type = 'Gradle' }
  elseif (Has $p '.vs') { $type = 'VisualStudio' }
  elseif ((Has $p 'Adobe Premiere Pro Video Previews') -or (Has $p 'Adobe Premiere Pro Audio Previews') -or (Has $p 'Media Cache Files') -or (Has $p 'Peak Files')) { $type = 'MediaCache' }
  if (-not $type) { continue }
  $regen = 0; $parts = @()
  foreach ($c in $regenNames[$type]) {
    $full = $p + $c + '\'; $s = Sz $full; if ($s -le 0) { continue }
    if ($c -eq '.venv' -or $c -eq 'venv') {
      # Only the interpreter environment is regenerable. People park outputs inside .venv too
      # (seen: 1.6 GB of tool runs and reports in a 2 GB .venv) - those must survive.
      $extra = 0; foreach ($k in (Kids $full)) { $leaf = [IO.Path]::GetFileName($k.Path.TrimEnd('\')); if ($venvParts -notcontains $leaf) { $extra += $k.Alloc } }
      if ($extra -gt 20MB) {
        foreach ($vp in $venvParts) { $s2 = Sz ($full + $vp + '\'); if ($s2 -gt 0) { $regen += $s2; $parts += ($full + $vp) } }
        $note = ("{0} holds {1:N2} GB that is not part of the environment - only Lib/Scripts/Include listed" -f $c, ($extra/1GB))
      } else { $regen += $s; $parts += ($p + $c) }
      continue
    }
    $regen += $s; $parts += ($p + $c)
  }
  $wf = WorkFolder $p
  $status = if (-not (IsCold $n.MaxMod)) { 'active' } elseif ($Nodes.ContainsKey($wf) -and -not (IsCold $Nodes[$wf].MaxMod)) { 'cold-in-active-folder' } else { 'cold' }
  $found.Add([pscustomobject]@{ Type = $type; GB = [math]::Round($n.Alloc/1GB,2); RegenGB = [math]::Round($regen/1GB,2); LastWrite = $n.MaxMod.Split(' ')[0]; Status = $status; Parts = $parts; Note = $note; Path = $p })
}
# keep outermost project when one is nested in another (e.g. a .vs inside a Unity project)
$projects = New-Object System.Collections.Generic.List[object]
foreach ($pr in ($found | Sort-Object Path)) { if (-not ($projects | Where-Object { $pr.Path.StartsWith($_.Path, 'OrdinalIgnoreCase') })) { $projects.Add($pr) } }

# ---- work-folder overview ----
$overview = New-Object System.Collections.Generic.List[object]
foreach ($r in $Roots) {
  foreach ($k in (Kids $r)) {
    $lv = @($k); if ($k.Alloc -ge 2GB) { $lv += @(Kids $k.Path) }
    foreach ($x in $lv) {
      if ($x.Alloc -lt 200MB) { continue }
      $rg = ($projects | Where-Object { $_.Path.StartsWith($x.Path, 'OrdinalIgnoreCase') } | Measure-Object RegenGB -Sum).Sum
      $overview.Add([pscustomobject]@{ GB = [math]::Round($x.Alloc/1GB,2); LastWrite = $x.MaxMod.Split(' ')[0]; Cold = (IsCold $x.MaxMod); RegenGB = [math]::Round([double]$rg,2); Path = $x.Path })
    }
  }
}

# ---- similar-named siblings / packaged builds ----
$zh = @(([string][char]0x6253 + [char]0x5305), ([string][char]0x526F + [char]0x672C), ([string][char]0x5907 + [char]0x4EFD), ([string][char]0x53EF + [char]0x8FD0 + [char]0x884C))
$kw = [regex]('(?i)((?<![a-z])(build|builds|release|export|package|packaged|backup|copy|old|final)(?![a-z])|' + ($zh -join '|') + ')')
function Base([string]$s) { ($s.ToLower() -replace '[\s\-_\.\(\)]','' -replace '(v?\d+)+$','') }
$dups = New-Object System.Collections.Generic.List[object]
foreach ($par in (($overview | ForEach-Object Path) + $Roots | Sort-Object -Unique)) {
  if ($par -match '(?i)\\(User Data|\.pnpm-store[^\\]*|node_modules)\\') { continue }   # browser profiles / package stores are numbered by design
  $ks = @(Kids $par | Where-Object { $_.Alloc -ge 100MB })
  if ($ks.Count -lt 2) { continue }
  # 2-4 similar names = versions of one thing; more than that is a systematic numbering (Profile 1..20, lab1..lab9)
  foreach ($g in ($ks | Group-Object { Base (Split-Path $_.Path.TrimEnd('\') -Leaf) } | Where-Object { $_.Count -gt 1 -and $_.Count -le 4 -and $_.Name.Length -ge 2 })) {
    foreach ($x in $g.Group) { $dups.Add([pscustomobject]@{ Why = 'similar-name'; GB = [math]::Round($x.Alloc/1GB,2); LastWrite = $x.MaxMod.Split(' ')[0]; Path = $x.Path }) }
  }
  foreach ($x in $ks) { if ($kw.IsMatch((Split-Path $x.Path.TrimEnd('\') -Leaf))) { $dups.Add([pscustomobject]@{ Why = 'build/backup-like name'; GB = [math]::Round($x.Alloc/1GB,2); LastWrite = $x.MaxMod.Split(' ')[0]; Path = $x.Path }) } }
}

# ---- output ----
Write-Host "`n== Work folders >= 200 MB (oldest activity first)"
$overview | Sort-Object LastWrite | Format-Table GB, LastWrite, Cold, RegenGB, Path -AutoSize | Out-String -Width 400
Write-Host "== Projects with regenerable artifacts > 50 MB"
$projects | Where-Object { $_.RegenGB -gt 0.05 } | Sort-Object Status, @{e='RegenGB';Descending=$true} | Format-Table Status, Type, GB, RegenGB, LastWrite, Path, Note -AutoSize | Out-String -Width 400
foreach ($st in 'cold','cold-in-active-folder','active') {
  $g = @($projects | Where-Object { $_.Status -eq $st -and $_.RegenGB -gt 0 }); if ($g) { Write-Host ("{0,-22} {1,3} projects  {2,7:N2} GB regenerable" -f $st, $g.Count, (($g | Measure-Object RegenGB -Sum).Sum)) }
}
Write-Host "Python venvs need dependencies re-downloaded to rebuild (can be GBs, e.g. torch); Unity/Unreal rebuild caches on next open."
if ($dups.Count) { Write-Host "`n== Similar-named siblings / packaged builds (>= 100 MB)"; $dups | Sort-Object Path -Unique | Format-Table Why, GB, LastWrite, Path -AutoSize | Out-String -Width 400 }

$rows = @()
$rows += $overview | ForEach-Object { [pscustomobject]@{ Section='work-folder'; Type=''; Status=$(if ($_.Cold) {'cold'} else {'active'}); GB=$_.GB; RegenGB=$_.RegenGB; LastWrite=$_.LastWrite; Path=$_.Path; Artifacts=''; Decision='' } }
$rows += $projects | Where-Object { $_.RegenGB -gt 0 } | ForEach-Object { [pscustomobject]@{ Section='project'; Type=$_.Type; Status=$_.Status; GB=$_.GB; RegenGB=$_.RegenGB; LastWrite=$_.LastWrite; Path=$_.Path; Artifacts=($_.Parts -join ' | '); Decision=''; Note=$_.Note } }
$rows += $dups | Sort-Object Path -Unique | ForEach-Object { [pscustomobject]@{ Section='possible-duplicate'; Type=$_.Why; Status=''; GB=$_.GB; RegenGB=''; LastWrite=$_.LastWrite; Path=$_.Path; Artifacts=''; Decision=''; Note='' } }
if (-not $NoReport) {
  $rows | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8
  Write-Host "Report: $OutCsv  (fill the Decision column: keep / clean / archive / delete)"
  # same retention as the scans: newest 3 reports per drive in the scan folder
  if ((Split-Path $OutCsv) -ieq (Split-Path $Csv)) {
    Get-ChildItem -LiteralPath (Split-Path $Csv) -Filter "${Drive}_projects-report_*.csv" | Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 |
      ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force; Write-Host "PRUNE: $($_.Name)" }
  }
}
if ($DeleteList) {
  # Last safety net: never emit anything inside node_modules packages or a program's install folder.
  $paths = $projects | Where-Object { $_.Status -eq 'cold' } | ForEach-Object { $_.Parts } | Where-Object { $_ -and $_ -notmatch '(?i)\\node_modules\\.+' }
  Set-Content -Path $DeleteList -Value $paths -Encoding UTF8
  Write-Host ("Delete list: {0} ({1} artifact folders of cold projects). Review, then: Remove-Paths.ps1 -ListFile <it> -Recycle never" -f $DeleteList, @($paths).Count)
}
