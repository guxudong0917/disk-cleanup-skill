<#
.SYNOPSIS
  From a WizTree *files* scan: installer packages, big files untouched for months, or recently written big files.
.DESCRIPTION
  Default: two reports outside Windows / Program Files / system folders:
    1) installer-like files (.msi/.msix/.iso/.apk, setup/install/update .exe, archives) >= -MinMB
    2) files >= -MinMB not modified for -MonthsOld months, plus the same grouped by folder
  -RecentHours N: instead list files >= 5 MB modified in the last N hours ("what just ate space").
  -Section installers|dups|old prints one part only (full output can exceed what a tool shows);
  -OutFile x.csv writes every row of every section, so nothing is lost to truncation.
.EXAMPLE
  .\Find-OldFiles.ps1 -MonthsOld 6 -MinMB 20
  .\Find-OldFiles.ps1 -RecentHours 1
#>
param(
  [string]$Csv,
  [int]$MonthsOld = 6,
  [double]$MinMB = 20,
  [double]$RecentHours = 0,
  [int]$Top = 30,
  [string]$Drive,
  [ValidateSet('all','installers','dups','old')][string]$Section = 'all',
  [string]$OutFile
)
. "$PSScriptRoot\WizTreeCsv.ps1"
if (-not $Csv) { $Csv = Get-LatestScan -Drive $(if ($Drive) { $Drive } else { $env:SystemDrive.Substring(0,1) }) -Mode 'files' }
Write-Host ("Scan: {0} ({1:yyyy-MM-dd HH:mm})" -f (Split-Path $Csv -Leaf), (Get-Item -LiteralPath $Csv).LastWriteTime)

$minBytes = $MinMB * 1MB
$sysRx = [regex]'^[A-Za-z]:\\(Windows\\|Program Files\\|Program Files \(x86\)\\|ProgramData\\Microsoft\\|ProgramData\\Package Cache\\|ProgramData\\Intel Package Cache[^\\]*\\|Recovery\\|System Volume Information\\|\$|pagefile\.sys|hiberfil\.sys|swapfile\.sys)'
. "$PSScriptRoot\InstallerRules.ps1"   # same name rule as Test-Installer.ps1
$archRx = [regex]'(?i)\.(zip|rar|7z|tar|gz)$'
# Duplicates only matter for the user's own files; program libraries (Anaconda pkgs, app .dll/.old) are noise.
$userDataRx = [regex]'(?i)\.(mp4|mov|mkv|avi|wmv|flv|m4v|ts|h264|h265|mp3|wav|flac|aac|m4a|jpg|jpeg|png|heic|raw|cr2|nef|psd|tif|tiff|zip|rar|7z|tar|gz|iso|pdf|ppt|pptx|doc|docx|xls|xlsx|csv|prproj|aep)$'
$libPathRx  = [regex]'(?i)\\(site-packages|pkgs|node_modules|\.venv|venv|Lib|Library|cache|\.cache)\\'

if ($RecentHours -gt 0) {
  $since = (Get-Date).AddHours(-$RecentHours)
  $rows = Read-WizTreeCsv $Csv $null 5MB 2 $since | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Alloc = $_.Alloc; Date = (ConvertTo-ScanDate $_.Modified) } }
  Write-Host ("== Files >= 5 MB written in the last {0} h: {1} files, {2:N2} GB" -f $RecentHours, @($rows).Count, (($rows | Measure-Object Alloc -Sum).Sum/1GB))
  $rows | Sort-Object Alloc -Descending | Select-Object -First $Top @{n='MB';e={[math]::Round($_.Alloc/1MB)}}, @{n='Time';e={$_.Date.ToString('MM-dd HH:mm')}}, Path | Format-Table -AutoSize | Out-String -Width 300
  return
}

$cut = (Get-Date).AddMonths(-$MonthsOld)
$installers = New-Object System.Collections.Generic.List[object]
$old = New-Object System.Collections.Generic.List[object]
$all = New-Object System.Collections.Generic.List[object]
$dumps = New-Object System.Collections.Generic.List[object]
$dumpRx = [regex]'(?i)\.(dmp|hdmp|mdmp)$'
foreach ($r in (Read-WizTreeCsv $Csv $null $minBytes 2)) {   # C# keeps only files >= MinMB: a few hundred rows
  # Crash dumps are worth listing even inside Windows\ (seen: a 2.5 GB .dmp in
  # C:\Windows\ServiceProfiles\LocalService\AppData\Local\Temp left from months earlier).
  if ($dumpRx.IsMatch($r.Path)) {
    $dd = ConvertTo-ScanDate $r.Modified
    $dumps.Add([pscustomobject]@{ MB = [math]::Round($r.Alloc/1MB); Date = $(if ($dd) { $dd.ToString('yyyy-MM-dd') } else { '?' }); Path = $r.Path }); continue
  }
  if ($sysRx.IsMatch($r.Path)) { continue }
  $d = ConvertTo-ScanDate $r.Modified
  $o = [pscustomobject]@{ MB = [math]::Round($r.Alloc/1MB); Date = $(if ($d) { $d.ToString('yyyy-MM-dd') } else { '?' }); Size = $r.Size; Path = $r.Path; Dir = [IO.Path]::GetDirectoryName($r.Path); Kind = '' }
  $nk = Get-InstallerNameKind ([IO.Path]::GetFileName($r.Path))
  if ($nk -eq 'package' -or $nk -eq 'setup-name') { $o.Kind = 'installer'; $installers.Add($o) }
  elseif ($nk -eq 'version-name') { $o.Kind = 'installer?'; $installers.Add($o) }
  elseif ($archRx.IsMatch($r.Path)) { $o.Kind = 'archive'; $installers.Add($o) }
  if ($userDataRx.IsMatch($r.Path) -and -not $libPathRx.IsMatch($r.Path)) { $all.Add($o) }   # duplicate check: user media/docs/archives only
  if ($d -and $d -lt $cut) { $old.Add($o) }
}
function Show([string]$name) { return ($Section -eq 'all' -or $Section -eq $name) }

# ---- installers / archives ----
$instDirs = $installers | Where-Object { $_.Kind -ne 'archive' } | ForEach-Object { $_.Dir } | Sort-Object -Unique
if (Show 'installers') {
  Write-Host ("== Installer packages / archives >= {0} MB: {1} files, {2:N2} GB  (archives may be user data - ask)" -f $MinMB, $installers.Count, (($installers | Measure-Object MB -Sum).Sum/1024))
  $installers | Sort-Object MB -Descending | Select-Object -First $Top | Format-Table MB, Date, Kind, Path -AutoSize | Out-String -Width 300
  Write-Host "installer = package or setup/install in the name; installer? = version/platform tag in the name only. Name-based: verify with Test-Installer."
  if ($dumps.Count) {
    Write-Host ("== Crash dumps >= {0} MB (any folder, including Windows\): {1} files, {2:N2} GB - diagnostic only, safe to delete once nobody is debugging that crash" -f $MinMB, $dumps.Count, (($dumps | Measure-Object MB -Sum).Sum/1024))
    $dumps | Sort-Object MB -Descending | Format-Table MB, Date, Path -AutoSize | Out-String -Width 300
  }
  if ($instDirs) {
    Write-Host "== Folders holding installer candidates - run Test-Installer.ps1 -Folder on EACH (names alone miss installers like SomeApp-win32-x64-*.exe):"
    $instDirs | ForEach-Object { "   $_" }
  }
}

# ---- possible duplicates among the big files (verify before deleting) ----
$dups = New-Object System.Collections.Generic.List[object]
foreach ($g in ($all | Group-Object Size | Where-Object { $_.Count -gt 1 })) {
  foreach ($x in $g.Group) { $dups.Add([pscustomobject]@{ Why = 'same size'; MB = $x.MB; Date = $x.Date; Path = $x.Path }) }
}
foreach ($dirGroup in ($all | Group-Object Dir | Where-Object { $_.Count -gt 1 })) {
  $arch = @($dirGroup.Group | Where-Object { $archRx.IsMatch($_.Path) })
  $plain = @($dirGroup.Group | Where-Object { -not $archRx.IsMatch($_.Path) })
  foreach ($a in $arch) { foreach ($p in $plain) {
    if ([math]::Abs($a.Size - $p.Size) -le 0.01 * [math]::Max($a.Size, $p.Size)) {
      $dups.Add([pscustomobject]@{ Why = 'archive ~ same size as sibling file'; MB = $a.MB; Date = $a.Date; Path = $a.Path })
      $dups.Add([pscustomobject]@{ Why = '  (sibling)'; MB = $p.MB; Date = $p.Date; Path = $p.Path })
    }
  } }
}
# archive with an extracted folder of the same name next to it (A.rar + A\): compare the archive's
# uncompressed total (zip entries / UnRAR l) with the folder size from the folders scan
$extracted = New-Object System.Collections.Generic.List[object]
foreach ($a in ($installers | Where-Object { $_.Kind -eq 'archive' })) {
  $base = [IO.Path]::GetFileNameWithoutExtension($a.Path) -replace '\.tar$',''
  $folder = Join-Path $a.Dir $base
  if (Test-Path -LiteralPath $folder -PathType Container) { $extracted.Add([pscustomobject]@{ ArchiveMB = $a.MB; Archive = $a.Path; Folder = $folder + '\' }) }
}
if ($extracted.Count) {
  try {
    $fcsv = Get-LatestScan -Drive $extracted[0].Archive.Substring(0,1) -Mode 'folders'
    $alt = ($extracted | ForEach-Object { [regex]::Escape($_.Folder) }) -join '|'
    $sizes = @{}; foreach ($r in (Read-WizTreeCsv $fcsv ([regex]::new('^"(?:' + $alt + ')",', 'IgnoreCase')))) { $sizes[$r.Path.ToLower()] = $r.Size }
    foreach ($e in $extracted) { $e | Add-Member FolderMB ([math]::Round([double]$sizes[$e.Folder.ToLower()]/1MB)) }
  } catch { }
}
if (Show 'dups') {
  if ($dups.Count) {
    Write-Host ("== Possible duplicates among user files >= {0} MB (confirm with Get-FileHash; for archive vs file hash the ENTRY inside the archive)" -f $MinMB)
    $dups | Format-Table Why, MB, Date, Path -AutoSize | Out-String -Width 300
  }
  if ($extracted.Count) {
    Write-Host "== Archives with an extracted folder of the same name next to them (candidates only: equal sizes prove nothing - run Compare-ArchiveFolder -Hash from WizTreeCsv.ps1; only 'identical' means the archive is redundant)"
    $extracted | Format-Table ArchiveMB, FolderMB, Archive -AutoSize | Out-String -Width 300
  }
}

# ---- old files ----
if (Show 'old') {
  Write-Host ("== Files >= {0} MB not modified for {1} months: {2} files, {3:N2} GB  (many are program binaries still in use)" -f $MinMB, $MonthsOld, $old.Count, (($old | Measure-Object MB -Sum).Sum/1024))
  $old | Sort-Object MB -Descending | Select-Object -First $Top | Format-Table MB, Date, Path -AutoSize | Out-String -Width 300
  Write-Host '== Same, grouped by folder (first 5 levels)'
  $old | Group-Object { $parts = $_.Path.Split('\'); ($parts[0..([math]::Min(5, $parts.Count - 2))]) -join '\' } |
    ForEach-Object { [pscustomobject]@{ MB = ($_.Group | Measure-Object MB -Sum).Sum; Files = $_.Count; Newest = ($_.Group | Sort-Object Date -Descending | Select-Object -First 1).Date; Folder = $_.Name } } |
    Sort-Object MB -Descending | Select-Object -First $Top | Format-Table -AutoSize | Out-String -Width 300
}

# ---- everything to a file, so nothing is lost to output truncation ----
if ($OutFile) {
  $rows = @()
  $rows += $dumps | ForEach-Object { [pscustomobject]@{ Section = 'crash-dump'; Kind = 'dump'; MB = $_.MB; Date = $_.Date; Path = $_.Path; Extra = '' } }
  $rows += $installers | ForEach-Object { [pscustomobject]@{ Section = 'installer-or-archive'; Kind = $_.Kind; MB = $_.MB; Date = $_.Date; Path = $_.Path; Extra = '' } }
  $rows += $dups | ForEach-Object { [pscustomobject]@{ Section = 'possible-duplicate'; Kind = $_.Why.Trim(); MB = $_.MB; Date = $_.Date; Path = $_.Path; Extra = '' } }
  $rows += $extracted | ForEach-Object { [pscustomobject]@{ Section = 'archive-with-extracted-folder'; Kind = 'archive'; MB = $_.ArchiveMB; Date = ''; Path = $_.Archive; Extra = "folder $($_.FolderMB) MB" } }
  $rows += $old | ForEach-Object { [pscustomobject]@{ Section = 'old'; Kind = $_.Kind; MB = $_.MB; Date = $_.Date; Path = $_.Path; Extra = '' } }
  $rows | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
  Write-Host "All rows ($($rows.Count)) written to $OutFile"
}
