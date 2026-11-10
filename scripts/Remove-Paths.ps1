<#
.SYNOPSIS
  Delete an approved list of files/folders. User data goes to the Recycle Bin; caches are deleted outright.
.DESCRIPTION
  Pass -Paths, or -ListFile (one path per line, UTF-8). Writes OK/RECYCLED/FAIL/GONE per path and the
  freed space to -Log (and to output).
  -Recycle auto (default): send to the Recycle Bin when the path is in a user-data area (Desktop, Documents,
     Downloads, Pictures, Videos, Music - including redirected locations - or anywhere on a non-system drive),
     UNLESS the item itself is a regenerable artifact (node_modules, .venv, Library, Intermediate, caches...),
     which is deleted outright (recycling 100k small files is slow and pointless).
  -Recycle always / never: force one behaviour.
  NOTE: recycled items still occupy the same drive until the Recycle Bin is emptied; the report says so.
  Run elevated for Program Files / ProgramData paths:
    Start-Process powershell -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"",'-ListFile',"`"$list`"",'-Log',"`"$log`""
  Files locked by a running program (often DLLs) fail with "access denied": stop the program or reboot, then retry.
#>
param(
  [string[]]$Paths,
  [string]$ListFile,
  [string]$Log,
  [ValidateSet('auto','always','never')][string]$Recycle = 'auto'
)
if ($ListFile) { $Paths += Get-Content -LiteralPath $ListFile -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() } }
# "powershell -File x.ps1 -Paths a,b" passes ONE string "a,b": split it back when it is not itself an existing path.
$Paths = @($Paths | ForEach-Object { if ($_ -match ',' -and -not (Test-Path -LiteralPath $_)) { $_ -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { $_ } })
if (-not $Paths) { throw 'Nothing to delete: pass -Paths or -ListFile.' }
Add-Type -AssemblyName Microsoft.VisualBasic

$guard = [regex]'(?i)^[A-Z]:\\?$|^[A-Z]:\\(Windows|Users|Program Files|Program Files \(x86\)|ProgramData|Recovery|System Volume Information)\\?$|^[A-Z]:\\Users\\[^\\]+\\?$|^[A-Z]:\\Users\\[^\\]+\\AppData(\\(Local|Roaming|LocalLow))?\\?$'
$sysDrive = $env:SystemDrive.Substring(0,1).ToUpper()
$userData = @('Desktop','MyDocuments','MyPictures','MyVideos','MyMusic') | ForEach-Object { [Environment]::GetFolderPath($_) } | Where-Object { $_ }
$userData += (Join-Path $env:USERPROFILE 'Downloads')
$userData = $userData | ForEach-Object { $_.TrimEnd('\') + '\' }
# Only names that are unambiguous artifacts. Generic names (build, Library, x64, Saved...) could be user folders,
# so in 'auto' they go to the Recycle Bin; for a verified artifact list from Find-ProjectArtifacts use -Recycle never.
$regenLeaf = [regex]'(?i)^(node_modules|\.venv|__pycache__|\.pytest_cache|\.mypy_cache|\.next|\.nuxt|\.parcel-cache|\.gradle|\.vs|ipch|DerivedDataCache|Media Cache Files|Peak Files|Adobe Premiere Pro (Audio|Video) Previews)$'

function Use-RecycleBin([string]$p) {
  if ($Recycle -eq 'always') { return $true }
  if ($Recycle -eq 'never') { return $false }
  $leaf = Split-Path $p.TrimEnd('\') -Leaf
  if ($regenLeaf.IsMatch($leaf)) { return $false }
  if ($p.Substring(0,1).ToUpper() -ne $sysDrive) { return $true }
  foreach ($u in $userData) { if (($p.TrimEnd('\') + '\').StartsWith($u, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
  return $false
}

$drives = $Paths | ForEach-Object { $_.Substring(0,1).ToUpper() } | Sort-Object -Unique
$before = @{}; foreach ($d in $drives) { $before[$d] = (Get-PSDrive $d).Free }
$out = @(); $recycled = 0
foreach ($t in $Paths) {
  if ($guard.IsMatch($t)) { $out += "SKIP (protected root) $t"; continue }
  if (-not (Test-Path -LiteralPath $t)) { $out += "GONE $t"; continue }
  try {
    $item = Get-Item -LiteralPath $t -Force
    if (Use-RecycleBin $t) {
      if ($item.PSIsContainer) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($item.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin') }
      else { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($item.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin') }
      $out += "RECYCLED $t"; $recycled++
      continue
    }
    # Fast path first: -Force already handles read-only/hidden files. Only if that fails, clear
    # attributes with native attrib (one process, not a PowerShell loop over 100k files) and retry.
    try { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction Stop }
    catch {
      if (-not (Test-Path -LiteralPath $t)) { throw }
      if ($item.PSIsContainer) { & attrib.exe -r -s -h "$t\*" /s /d 2>$null | Out-Null; & attrib.exe -r -s -h "$t" 2>$null | Out-Null }
      else { & attrib.exe -r -s -h "$t" 2>$null | Out-Null }
      Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction Stop
    }
    $out += "OK   $t"
  } catch { $out += "FAIL $t : $($_.Exception.Message)" }
}
foreach ($d in $drives) { $after = (Get-PSDrive $d).Free; $out += ("Drive {0}: freed {1:N2} GB, free now {2:N2} GB" -f $d, (($after - $before[$d])/1GB), ($after/1GB)) }
if ($recycled) { $out += "$recycled item(s) went to the Recycle Bin: restorable from there, but their space is only freed after emptying it." }
if ($Log) { $out | Set-Content -Path $Log -Encoding UTF8 }
$out
