<#
.SYNOPSIS
  List the direct subfolders of one or more folders with their sizes, from a WizTree folders scan (no disk walk).
.DESCRIPTION
  Pass several paths at once: the scan is read only once per drive (each separate call costs ~1.5 s of start-up).
.EXAMPLE
  .\Get-FolderSizes.ps1 -Path 'C:\Users\me\AppData\Local' -Top 20
  .\Get-FolderSizes.ps1 -Path 'D:\','D:\Users\me\Desktop','D:\$RECYCLE.BIN' -Top 10
#>
param(
  [Parameter(Mandatory)][string[]]$Path,
  [string]$Csv,
  [int]$Top = 20,
  [double]$MinMB = 0
)
. "$PSScriptRoot\WizTreeCsv.ps1"
# "powershell -File x.ps1 -Path a,b" passes ONE string "a,b": split it back when it is not itself an existing path.
$Path = @($Path | ForEach-Object { if ($_ -match ',' -and -not (Test-Path -LiteralPath $_)) { $_ -split ',' } else { $_ } } | ForEach-Object { $_.Trim().TrimEnd('\') + '\' } | Where-Object { $_.Length -gt 1 })

foreach ($grp in ($Path | Group-Object { $_.Substring(0,1).ToUpper() })) {
  $scan = if ($Csv) { $Csv } else { Get-LatestScan -Drive $grp.Name -Mode 'folders' }
  Write-Host ("Scan: {0}" -f (Split-Path $scan -Leaf))
  $parents = @($grp.Group)
  $alt = ($parents | ForEach-Object { [regex]::Escape($_) }) -join '|'
  $rx = [regex]::new('^"(?:(?:' + $alt + ')[^\\"]+\\|' + $alt + ')",', 'IgnoreCase')
  $rows = Read-WizTreeCsv $scan $rx
  foreach ($p in $parents) {
    $self = $rows | Where-Object { $_.Path -ieq $p } | Select-Object -First 1
    if ($self) { Write-Host ("`n{0}  total {1:N2} GB" -f $p, ($self.Alloc / 1GB)) } else { Write-Host ("`n{0}  (not in scan)" -f $p); continue }
    $rows | Where-Object { $_.Path.Length -gt $p.Length -and $_.Path.StartsWith($p, [StringComparison]::OrdinalIgnoreCase) -and $_.Path.IndexOf('\', $p.Length) -eq $_.Path.Length - 1 -and $_.Alloc / 1MB -ge $MinMB } |
      Sort-Object Alloc -Descending | Select-Object -First $Top |
      Select-Object @{n='GB';e={[math]::Round($_.Alloc/1GB,2)}}, @{n='Modified';e={$_.Modified.Split(' ')[0]}}, @{n='Folder';e={$_.Path.Substring($p.Length).TrimEnd('\')}} |
      Format-Table -AutoSize | Out-String -Width 300
  }
}
