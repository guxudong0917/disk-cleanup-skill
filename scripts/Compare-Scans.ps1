<#
.SYNOPSIS
  Compare two WizTree folders scans and show which folders grew (or shrank) the most.
.DESCRIPTION
  Defaults to the two most recent folders scans of -Drive. Prints top-level changes and the
  largest changes at -Depth (deeper = more specific, e.g. 4 = C:\Users\me\AppData\Local\X).
.EXAMPLE
  .\Compare-Scans.ps1
  .\Compare-Scans.ps1 -Old D:\WizTreeScans\C_folders_20261101-0900.csv -Depth 5
#>
param(
  [string]$Drive = 'C',
  [string]$Old,
  [string]$New,
  [int]$Depth = 4,
  [int]$Top = 25,
  [double]$MinMB = 50
)
. "$PSScriptRoot\WizTreeCsv.ps1"
if (-not $New) { $New = Get-LatestScan -Drive $Drive -Mode 'folders' -Skip 0 }
if (-not $Old) { $Old = Get-LatestScan -Drive $Drive -Mode 'folders' -Skip 1 }
Write-Host ("Old: {0}`nNew: {1}" -f (Split-Path $Old -Leaf), (Split-Path $New -Leaf))
# C# does the per-line work; PowerShell only shapes rows at depth 0, 1 and -Depth that changed by >= 1 MB.
$diff = [WtCsv]::Compare($Old, $New, $Depth) | Where-Object { ($_.Depth -le 1 -or $_.Depth -eq $Depth) -and [math]::Abs($_.NewAlloc - $_.OldAlloc) -ge 1MB } | ForEach-Object {
  [pscustomobject]@{ DeltaMB = [math]::Round(($_.NewAlloc - $_.OldAlloc)/1MB); NowMB = [math]::Round($_.NewAlloc/1MB); Status = $(if ($_.OldAlloc -eq 0) {'new'} elseif ($_.NewAlloc -eq 0) {'gone'} else {''}); Depth = $_.Depth; Path = $_.Path }
}
$root = $diff | Where-Object { $_.Depth -eq 0 }
if ($root) { Write-Host ("Drive total change: {0:N0} MB" -f $root[0].DeltaMB) }
Write-Host "`n== Top-level folders"
$diff | Where-Object { $_.Depth -eq 1 -and [math]::Abs($_.DeltaMB) -ge 1 } | Sort-Object DeltaMB -Descending | Format-Table DeltaMB, NowMB, Status, Path -AutoSize | Out-String -Width 300
Write-Host "== Biggest growth at depth $Depth (>= $MinMB MB)"
$diff | Where-Object { $_.Depth -eq $Depth -and $_.DeltaMB -ge $MinMB } | Sort-Object DeltaMB -Descending | Select-Object -First $Top | Format-Table DeltaMB, NowMB, Status, Path -AutoSize | Out-String -Width 300
Write-Host "== Biggest shrink at depth $Depth"
$diff | Where-Object { $_.Depth -eq $Depth -and $_.DeltaMB -le -$MinMB } | Sort-Object DeltaMB | Select-Object -First 10 | Format-Table DeltaMB, NowMB, Status, Path -AutoSize | Out-String -Width 300
