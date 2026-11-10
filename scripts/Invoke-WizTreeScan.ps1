<#
.SYNOPSIS
  Export a WizTree scan of a drive to a fixed folder and reuse recent scans.
.DESCRIPTION
  Writes <ScanDir>\<Drive>_<mode>_<yyyyMMdd-HHmm>.csv and prints its full path as the last
  output line. If a scan of the same drive+mode newer than -MaxAgeHours exists, it is reused
  (no rescan) unless -Force. Old scans beyond -Keep per drive+mode are pruned.
  WizTree runs elevated (/admin=1) so it can read the MFT: a UAC prompt appears.
.EXAMPLE
  .\Invoke-WizTreeScan.ps1 -Drive C -Mode folders
  .\Invoke-WizTreeScan.ps1 -Drive C -Mode files -Force
#>
param(
  [string]$Drive = 'C',
  [ValidateSet('folders','files')][string]$Mode = 'folders',
  [string]$ScanDir,
  [double]$MaxAgeHours = 6,
  [int]$Keep = 0,   # per drive+mode; 0 = config "Keep" or 3 (newest = current state, older = baselines for Compare-Scans)
  [switch]$Force,
  [string]$WizTreePath
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Config.ps1"
$cfg = $script:DiskCleanupConfig
if (-not $ScanDir -and $cfg.ScanDir) { $ScanDir = $cfg.ScanDir }
if (-not $WizTreePath -and $cfg.WizTreePath) { $WizTreePath = $cfg.WizTreePath }
if ($Keep -le 0) { $Keep = if ($cfg.Keep) { [int]$cfg.Keep } else { 3 } }
$Drive = $Drive.TrimEnd(':','\').ToUpper()

function Find-WizTree {
  $keys = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
          'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
          'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
  $e = Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'WizTree' } | Select-Object -First 1
  $cands = @()
  if ($e -and $e.InstallLocation) { $cands += (Join-Path $e.InstallLocation 'WizTree64.exe') }
  $cands += "$env:ProgramFiles\WizTree\WizTree64.exe", "${env:ProgramFiles(x86)}\WizTree\WizTree64.exe"
  # portable copies are often unpacked to <drive>:\WizTree
  $cands += Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' } | ForEach-Object { "$($_.Root)WizTree\WizTree64.exe" }
  foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
  return $null
}

if (-not $ScanDir) {
  $sys = $env:SystemDrive.TrimEnd(':').ToUpper()
  $other = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -ne $sys -and $_.Free -gt 2GB -and $_.Root -match '^[A-Z]:\\$' } | Sort-Object Name | Select-Object -First 1
  if ($other) { $ScanDir = "$($other.Name):\WizTreeScans" }
  else { $ScanDir = Join-Path $env:USERPROFILE 'WizTreeScans'; Write-Host "WARN: no non-system drive found, saving scans to $ScanDir" }
}
New-Item -ItemType Directory -Force -Path $ScanDir | Out-Null

$pattern = "${Drive}_${Mode}_*.csv"
$existing = Get-ChildItem -LiteralPath $ScanDir -Filter $pattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
if (-not $Force -and $existing -and ((Get-Date) - $existing[0].LastWriteTime).TotalHours -lt $MaxAgeHours) {
  Write-Host ("REUSE: scan from {0:yyyy-MM-dd HH:mm} ({1:N1} h old). Use -Force to rescan." -f $existing[0].LastWriteTime, ((Get-Date) - $existing[0].LastWriteTime).TotalHours)
  Write-Output $existing[0].FullName
  return
}

if (-not $WizTreePath) { $WizTreePath = Find-WizTree }
if (-not $WizTreePath) { throw 'WizTree not found. Install it (https://diskanalyzer.com), pass -WizTreePath, or set "WizTreePath" in %USERPROFILE%\.disk-cleanup\config.json.' }

$out = Join-Path $ScanDir ("{0}_{1}_{2:yyyyMMdd-HHmm}.csv" -f $Drive, $Mode, (Get-Date))
$argList = @("`"${Drive}:\`"", "/export=`"$out`"", '/admin=1')
if ($Mode -eq 'folders') { $argList += '/exportfolders=1', '/exportfiles=0' } else { $argList += '/exportfolders=0', '/exportfiles=1' }

Write-Host "SCAN: running WizTree on ${Drive}: ($Mode). Approve the UAC prompt if it appears..."
$t = Get-Date
Start-Process -FilePath $WizTreePath -ArgumentList $argList -Verb RunAs -Wait
if (-not (Test-Path -LiteralPath $out)) { throw "WizTree finished but no export at $out (UAC declined?)" }
Write-Host ("DONE: {0:N1}s, {1:N1} MB" -f ((Get-Date) - $t).TotalSeconds, ((Get-Item -LiteralPath $out).Length / 1MB))

$all = Get-ChildItem -LiteralPath $ScanDir -Filter $pattern | Sort-Object LastWriteTime -Descending
if ($all.Count -gt $Keep) { $all | Select-Object -Skip $Keep | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force; Write-Host "PRUNE: $($_.Name)" } }

Write-Output $out
