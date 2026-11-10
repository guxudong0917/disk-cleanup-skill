<#
.SYNOPSIS
  List (and optionally remove) uninstall entries whose uninstaller file no longer exists -
  the apps in Settings > Apps that fail with "Windows cannot find ... uninstall.exe".
.DESCRIPTION
  Report only by default. With -Remove (needs admin for HKLM entries): exports all broken keys
  into one .reg backup (double-click it to restore), deletes them, writes -Log.
  Entries driven by msiexec / rundll32 (MSI, ClickOnce) are skipped: their uninstall string is not a file path.
.EXAMPLE
  .\Find-BrokenUninstallEntries.ps1
  .\Find-BrokenUninstallEntries.ps1 -Remove -Backup 'D:\WizTreeScans\uninstall-backup.reg' -Log C:\temp\u.log
#>
param(
  [switch]$Remove,
  [string]$Backup,
  [string]$Log
)
$roots = @(
  @{ ps = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall';             reg = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall' },
  @{ ps = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall';             reg = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall' },
  @{ ps = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; reg = 'HKLM\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' }
)
$found = @()
foreach ($r in $roots) {
  foreach ($k in Get-ChildItem $r.ps -ErrorAction SilentlyContinue) {
    $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
    if (-not $p.DisplayName -or -not $p.UninstallString) { continue }
    $s = $p.UninstallString.Trim()
    if ($s -match '^"([^"]+)"') { $exe = $matches[1] } elseif ($s -match '^(.+?\.exe)') { $exe = $matches[1] } else { continue }
    if ($exe -match '(?i)(msiexec|rundll32)(\.exe)?$' -or $exe -notmatch '\\') { continue }
    if (-not (Test-Path -LiteralPath $exe)) {
      $loc = if ($p.InstallLocation) { $p.InstallLocation.Trim('"') } else { Split-Path $exe }
      $found += [pscustomobject]@{ Name = $p.DisplayName; FolderExists = [bool](Test-Path -LiteralPath $loc); Uninstaller = $exe; Reg = "$($r.reg)\$($k.PSChildName)"; PSPath = $k.PSPath }
    }
  }
}
$found | Sort-Object Name | Format-Table Name, FolderExists, Uninstaller -AutoSize | Out-String -Width 300
Write-Host "$($found.Count) broken entries. FolderExists=True means program files are still there (half-broken install) - mention it to the user."
if (-not $Remove -or $found.Count -eq 0) { return }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Removing HKLM entries needs admin. Re-run this script elevated (Start-Process -Verb RunAs -File ...).' }
if (-not $Backup) { $Backup = Join-Path ([Environment]::GetFolderPath('Desktop')) ("uninstall-entries-backup-{0:yyyyMMdd-HHmm}.reg" -f (Get-Date)) }
$out = @()
$lines = @('Windows Registry Editor Version 5.00', '')
$tmp = [IO.Path]::GetTempFileName()
foreach ($f in $found) {
  & reg.exe export $f.Reg $tmp /y | Out-Null
  if ($LASTEXITCODE -ne 0) { $out += "BACKUP FAIL $($f.Name) - not deleted"; $f.PSPath = $null; continue }
  $lines += (Get-Content $tmp -Encoding Unicode | Select-Object -Skip 1)
}
Remove-Item $tmp -Force
Set-Content -Path $Backup -Value $lines -Encoding Unicode
$out += "Backup: $Backup"
foreach ($f in $found) {
  if (-not $f.PSPath) { continue }
  try { Remove-Item -LiteralPath $f.PSPath -Recurse -Force -ErrorAction Stop; $out += "DELETED $($f.Name)" }
  catch { $out += "FAIL $($f.Name): $($_.Exception.Message)" }
}
if ($Log) { $out | Set-Content -Path $Log -Encoding UTF8 }
$out
