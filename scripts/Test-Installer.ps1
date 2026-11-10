<#
.SYNOPSIS
  Decide whether .exe/.msi files are installer packages (safe to delete once the app is installed)
  or programs that are actually used (must keep). Read-only.
.DESCRIPTION
  Evidence per file:
    - name pattern   : setup / install / installer / Chinese "an zhuang" / version numbers / x64
    - version info   : FileDescription / ProductName / OriginalFilename mention setup, installer, install
    - packer marker  : NSIS, Inno Setup, InstallShield, WiX Burn, Squirrel, Advanced Installer, 7z SFX,
                       Setup Factory, InstallAware (searched in the first 2 MB and last 256 KB)
    - extension      : .msi / .msix / .appx / .apk / .iso are packages by definition
    - companions     : .dll / .pak / resources next to it => it is part of an installed program (KEEP)
    - installed      : ProductName matches an uninstall entry => installer is redundant
  Verdict: installer (2+ signals or package extension) / likely-installer (1 signal) / program (has companions
  or none) / unknown. Only "installer" should be deleted without asking; show the rest to the user.
.EXAMPLE
  .\Test-Installer.ps1 -Folder D:\            # non-recursive: loose files in a folder
  .\Test-Installer.ps1 -Paths 'D:\new_tdx.exe','D:\x.exe'
#>
param(
  [string[]]$Paths,
  [string]$Folder,
  [double]$MinMB = 0,
  [switch]$WithSignature   # Authenticode check can hit the network (revocation) and is slow: only when asked
)
if ($Folder) {
  # "cannot read" must not look like "no installers here"
  try { $Paths += Get-ChildItem -LiteralPath $Folder -File -Force -ErrorAction Stop | Where-Object { $_.Extension -match '^\.(exe|msi|msix|msixbundle|appx|apk|iso)$' } | ForEach-Object FullName }
  catch { Write-Host "CANNOT CHECK $Folder : $($_.Exception.Message) - result unknown, not 'no installers'"; exit 3 }
}
# "powershell -File x.ps1 -Paths a,b" passes ONE string "a,b": split it back when it is not itself an existing path.
$Paths = @($Paths | Where-Object { $_ } | ForEach-Object { if ($_ -match ',' -and -not (Test-Path -LiteralPath $_)) { $_ -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } } else { $_ } })
if (-not $Paths) { Write-Host 'No candidate files.'; return }

. "$PSScriptRoot\InstallerRules.ps1"   # same name rule as Find-OldFiles.ps1
$descRx = [regex]'(?i)(setup|installer|install|bootstrapper|downloader|web ?installer)'
$markers = @('Nullsoft','NSIS Error','Inno Setup','InstallShield','.wixburn','WixBundle','Squirrel','Advanced Installer','7z SFX','7-Zip SFX','Setup Factory','InstallAware','Smart Install Maker','Wise Installation')

$apps = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue | Where-Object DisplayName
$appNames = ($apps | ForEach-Object DisplayName) -join '|'
$appNorm = ($appNames.ToLower() -replace '[\s\-_\.]','')

function Find-Marker([string]$path) {
  try {
    $fs = [IO.File]::OpenRead($path)
    try {
      $len = $fs.Length; $head = [Math]::Min($len, 2MB)
      $buf = New-Object byte[] $head; [void]$fs.Read($buf, 0, $head)
      $txt = [Text.Encoding]::ASCII.GetString($buf)
      if ($len -gt $head) { $tail = [Math]::Min($len - $head, 256KB); $fs.Seek(-$tail, 'End') | Out-Null; $b2 = New-Object byte[] $tail; [void]$fs.Read($b2, 0, $tail); $txt += [Text.Encoding]::ASCII.GetString($b2) }
      foreach ($m in $markers) { if ($txt.IndexOf($m, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $m } }
    } finally { $fs.Dispose() }
  } catch {}
  return ''
}

# Per folder: which company/product groups exist among exe/dll files. 3+ files from one company in a folder
# (or an uninstaller) means an installed program lives there, so its exe/msix files are components, not installers.
$folderGroups = @{}
function Get-Group([IO.FileInfo]$f) {
  $dir = $f.DirectoryName
  if (-not $folderGroups.ContainsKey($dir)) {
    $g = @{}
    # Microsoft runtime DLLs (vcruntime, msvcp, ucrt, api-ms-*) ship inside many third-party programs; they do
    # not tell which program lives here (seen: QEMU's exe reported as a "Microsoft Corporation" component).
    # Skipping them by name also avoids reading their version info (the slow part in big folders).
    foreach ($x in (Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(exe|dll)$' -and $_.Name -notmatch '(?i)^(api-ms-|ext-ms-|vcruntime|msvcp|msvcr|ucrtbase|concrt|vccorlib|mfc\d|vcomp|d3dcompiler|dbghelp)' })) {
      $c = $x.VersionInfo.CompanyName; if (-not $c) { continue }
      if (-not $g.ContainsKey($c)) { $g[$c] = New-Object System.Collections.Generic.List[object] }
      $g[$c].Add($x)
    }
    $folderGroups[$dir] = $g
  }
  $groups = $folderGroups[$dir]
  $c = $f.VersionInfo.CompanyName
  if ($c -and $groups.ContainsKey($c) -and $groups[$c].Count -ge 3) { return $c }
  $prod = $f.VersionInfo.ProductName
  foreach ($k in $groups.Keys) {
    if ($groups[$k].Count -lt 3) { continue }
    if ($k -match '^Microsoft' -and $c -notmatch '^Microsoft') { continue }   # bundled MS libraries say nothing about a third-party exe
    # same product name as an installed program's files (e.g. WinRAR's shell-extension installer)
    if ($prod -and ($groups[$k] | Where-Object { $_.VersionInfo.ProductName -eq $prod })) { return $k }
    # its description/product mentions the installed program's product name (e.g. "WinRAR shell extension installer")
    $text = "$($f.VersionInfo.FileDescription) $prod"
    $tokens = $groups[$k] | ForEach-Object { "$($_.VersionInfo.ProductName) $($_.VersionInfo.FileDescription)" -split '[\s\(\)\-_,]+' } |
      Where-Object { $_ -match '^[A-Za-z][A-Za-z0-9]{3,}$' -and $_ -notmatch '^(Microsoft|Windows|Setup|Installer|Install|Program|Application|Software|Corporation|Version|Command|Line)$' } | Sort-Object -Unique
    foreach ($tk in $tokens) { if ($text -match ('(?i)(?<![A-Za-z])' + [regex]::Escape($tk) + '(?![A-Za-z])')) { return $k } }
    # no version info (.msix/.msi/.dat): shipped together with the program (within 30 days)
    if (-not $c -and ($groups[$k] | Where-Object { [math]::Abs(($_.LastWriteTime - $f.LastWriteTime).TotalDays) -lt 30 })) { return $k }
  }
  return $null
}

function Norm([string]$s) { if (-not $s) { return '' }; return ($s.ToLower() -replace '[\s\-_\.\(\)]','') }
function To-Version([string]$s) { if ($s -match '(\d+)(\.\d+){0,3}') { try { return [version](($matches[0] -split '\.' | Select-Object -First 4) -join '.' -replace '^(\d+)$','$1.0') } catch {} }; return $null }
# installed programs: match on display name, install path and publisher (the exe's ProductName is often an
# internal name, e.g. BaiduNetdisk's installer says "BaiduYunguanjia" while the entry is "Baidu Netdisk" in Chinese)
$appIdx = $apps | ForEach-Object {
  $raw = ''
  try { $raw = if ($_.InstallLocation) { $_.InstallLocation.Trim('"') } elseif ($_.DisplayIcon) { Split-Path (($_.DisplayIcon -split ',')[0].Trim('"')) } else { '' } } catch {}
  if ($raw) { $raw = $raw.TrimEnd('\') + '\' }
  [pscustomobject]@{ Name = $_.DisplayName; Ver = $_.DisplayVersion; Key = (Norm $_.DisplayName); Loc = (Norm "$($_.InstallLocation)|$($_.DisplayIcon)|$($_.UninstallString)"); Pub = (Norm $_.Publisher); RawLoc = $raw }
}
# Scored, best match wins (first-match-wins caused: ChromeSetup -> "Google Drive" via the shared publisher,
# nvm-setup -> "Node.js" because its description "Node.js version manager" contains that app's name).
#   5 exact name, 4 app name starts with the key, 3 app name contains the key, 2 key contains the app name
#   (product/file name only, never the description) or install path contains the key, 1 same publisher only.
# A key that is just the vendor ("Google Installer" -> "google") says nothing about the product: ignored.
# Score 1 is reported as "publisher only" and gets no same/older/NEWER verdict.
function Find-InstalledApp([IO.FileInfo]$f) {
  $vi = $f.VersionInfo
  $noise = '(?i)\s*\((x86|x64|32-?bit|64-?bit)\)|\b(web ?installer|setup|installer|install|bootstrapper|downloader)\b'
  $vendor = Norm ($vi.CompanyName -replace '(?i)[,\.]?\s*\b(llc|inc|ltd|limited|corp|corporation|co|gmbh|s\.?a|software|technologies|technology)\b\.?','')
  $prodK = Norm ($vi.ProductName -replace $noise,'')
  $descK = Norm ($vi.FileDescription -replace $noise,'')
  $baseK = Norm (($f.BaseName -replace '(?i)([-_ .]v?\d.*|[-_ ](setup|install|installer|win32|win64|x64|amd64|latest|windows).*)$','') -replace '(?i)(web)?(setup|installer|install)$','')
  # a key equal to the vendor only counts as an exact name match (CC Switch by "CC Switch" is fine, "google" is not)
  $nameKeys = @($prodK, $baseK) | Where-Object { $_.Length -ge 3 } | Sort-Object -Unique
  if ($descK.Length -lt 4) { $descK = '' }
  $co = Norm $vi.CompanyName
  $best = $null; $bestScore = 0
  foreach ($a in $appIdx) {
    $s = 0
    foreach ($k in $nameKeys) {
      $t = if ($a.Key -eq $k) { 5 } elseif ($k -eq $vendor) { 0 } elseif ($a.Key.StartsWith($k)) { 4 } elseif ($k.Length -ge 4 -and $a.Key.Contains($k)) { 3 }
           elseif (($a.Key.Length -ge 4 -and $k.Contains($a.Key)) -or ($k.Length -ge 4 -and $a.Loc.Contains($k))) { 2 } else { 0 }
      if ($t -gt $s) { $s = $t }
    }
    if ($descK) { $t = if ($a.Key -eq $descK) { 4 } elseif ($descK -eq $vendor) { 0 } elseif ($a.Key.StartsWith($descK)) { 4 } elseif ($a.Key.Contains($descK)) { 3 } else { 0 }; if ($t -gt $s) { $s = $t } }
    if ($s -eq 0 -and $co.Length -ge 6 -and $a.Pub -and ($a.Pub.Contains($co) -or $co.Contains($a.Pub))) { $s = 1 }
    if ($s -gt $bestScore) { $best = $a; $bestScore = $s }
  }
  if ($best) { $best | Add-Member -NotePropertyName Score -NotePropertyValue $bestScore -Force }
  return $best
}

$res = foreach ($p in $Paths) {
  if (-not (Test-Path -LiteralPath $p)) { continue }
  $f = Get-Item -LiteralPath $p -Force
  if ($f.Length / 1MB -lt $MinMB) { continue }
  $signals = @()
  # Cheapest decisive check first: part of a program installed in this same folder? Then skip reading the file.
  $group = Get-Group $f
  if ($group -or $f.Name -match '(?i)^unins|uninstall') {
    [pscustomobject]@{ MB = [math]::Round($f.Length/1MB,1); Verdict = 'program-component'; Installed = ''; Signals = "same-folder-as:$group"; Description = $f.VersionInfo.FileDescription; Signer = ''; Name = $f.Name; Path = $f.FullName }
    continue
  }
  if ($f.Extension -match '^\.(msi|msix|msixbundle|appx|apk|iso)$') { $signals += 'package-ext'; $signals += 'package-ext' }
  $nk = Get-InstallerNameKind $f.Name
  if ($nk -eq 'setup-name' -or $nk -eq 'version-name') { $signals += 'name' }
  $vi = $f.VersionInfo
  $desc = "$($vi.FileDescription) | $($vi.ProductName) | $($vi.OriginalFilename)"
  if ($descRx.IsMatch($desc)) { $signals += 'version-info' }
  # reading 2 MB + 256 KB per exe is the slow part: only when the cheap signals have not decided yet
  $mk = ''; $mkDone = $false
  if ($f.Extension -ieq '.exe' -and $signals.Count -lt 2) { $mk = Find-Marker $f.FullName; $mkDone = $true; if ($mk) { $signals += "packer:$mk" } }
  $dir = $f.DirectoryName
  $comp = @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(dll|pak|dat|asar|pri)$' -and [math]::Abs(($_.LastWriteTime - $f.LastWriteTime).TotalDays) -lt 2 }).Count
  $app = Find-InstalledApp $f
  $installed = ''; $rel = ''
  if ($app -and $app.Score -eq 1) {
    $installed = "? same publisher as $($app.Name) $($app.Ver) (publisher only)"; $app = $null
  } elseif ($app) {
    $fv = To-Version $(if ($vi.ProductVersion) { $vi.ProductVersion } else { $f.BaseName }); $av = To-Version $app.Ver
    $rel = if ($fv -and $av) { if ($fv -eq $av) { 'same' } elseif ($fv -lt $av) { 'older' } else { 'NEWER' } } else { '?' }
    $installed = "$($app.Name) $($app.Ver) ($rel)"
  }
  # Identity check: the file NAME claims a product ("Clash.Verge_2.4.4.exe"); does the file's own metadata agree?
  # Seen: a fake "Clash.Verge_2.4.4.exe" whose description was "FormCeo", version 1.0.0.0, unsigned - the infection
  # source of a backdoor. A name-derived version must never be read as the program's real version.
  $idNote = ''
  if ($f.Extension -ieq '.exe' -and ($nk -or $app)) {
    $stop = '^(setup|install|installer|win|win32|win64|x64|x86|amd64|arm64|portable|latest|full|online|offline|release|beta|exe|msi|the|and|for)$'
    $claim = @(($f.BaseName -creplace '([a-z])([A-Z])', '$1 $2') -split '[^A-Za-z]+' | Where-Object { $_.Length -ge 3 -and $_ -notmatch $stop })
    if ($app) { $claim += @($app.Name -split '[^A-Za-z]+' | Where-Object { $_.Length -ge 3 -and $_ -notmatch $stop }) }
    $meta = "$($vi.FileDescription) $($vi.ProductName) $($vi.OriginalFilename) $($vi.InternalName) $($vi.CompanyName)"
    $agrees = (-not $claim) -or ($claim | Where-Object { $meta -match ('(?i)' + [regex]::Escape($_)) } | Select-Object -First 1)
    if (-not $agrees) {
      if (-not $mkDone) { $mk = Find-Marker $f.FullName; if ($mk) { $signals += "packer:$mk" } }
      if ($meta.Trim()) { $idNote = "name says '$($claim[0..1] -join ' ')' but file says '$(($vi.FileDescription, $vi.ProductName | Where-Object { $_ }) -join ' / ')'" }
      # no metadata at all is normal for many real programs (qemu-system-x86_64.exe): only suspicious when the
      # name claims to be a setup or an installed product, and the file is not part of a program folder
      elseif (-not $mk -and ($nk -eq 'setup-name' -or $app) -and $comp -lt 3) { $idNote = "name says '$($claim[0..1] -join ' ')' but the file has no version info and no installer framework" }
    }
  }
  $sig = if ($WithSignature) { (Get-AuthenticodeSignature -LiteralPath $f.FullName -ErrorAction SilentlyContinue).SignerCertificate.Subject -replace '^CN="?([^,"]+).*','$1' } else { '' }
  $n = $signals.Count
  $verdict = if ($comp -ge 3 -and -not ($signals -match 'packer|package')) { 'program' }
             elseif ($n -ge 2) { 'installer' } elseif ($n -eq 1) { 'likely-installer' } else { 'program?' }
  # A program here that is an OLDER version of the same product installed ELSEWHERE is a stale copy
  # (seen: v9 of an app unpacked into D:\ while v10 is installed in C:\Program Files\<App>).
  if ($verdict -like 'program*' -and $rel -eq 'older' -and $app.RawLoc -and -not (($f.DirectoryName.TrimEnd('\') + '\').StartsWith($app.RawLoc, [StringComparison]::OrdinalIgnoreCase))) {
    $verdict = 'stale-copy'; $installed += " at $($app.RawLoc)"
  }
  if ($idNote) { $verdict = 'identity-mismatch'; $signals += $idNote; $installed = if ($installed -and $installed -notlike '?*') { "(by name only) $installed" } else { '' } }
  [pscustomobject]@{ MB = [math]::Round($f.Length/1MB,1); Verdict = $verdict; Installed = $installed; Signals = ($signals | Select-Object -Unique) -join ','; Description = $vi.FileDescription; Signer = $sig; Name = $f.Name; Path = $f.FullName }
}
$cols = @('MB','Verdict','Installed','Signals','Description','Name'); if ($WithSignature) { $cols += 'Signer' }
$res | Sort-Object @{e={ @{ 'identity-mismatch'=-1; 'installer'=0; 'stale-copy'=1; 'likely-installer'=2; 'program?'=3; 'program'=4; 'program-component'=5 }[$_.Verdict] }}, @{e='MB';Descending=$true} |
  Format-Table $cols -AutoSize | Out-String -Width 300
Write-Host 'identity-mismatch = the file name claims a product/version that the file itself does not confirm. Not cleanup: check it as a possible fake (SKILL.md section 3d) before anything else.'
Write-Host 'installer = 2+ signals; likely-installer = 1 signal (confirm with the user); program / program? = keep;'
Write-Host 'program-component = belongs to a program installed in the same folder (3+ files from the same company, or an uninstaller) - never delete.'
Write-Host 'stale-copy = OLDER version of a product installed elsewhere (path shown): an old portable/unpacked copy. Report as removable (user decides); remove its whole file set (look for uninstall.log next to it), not just the exe.'
Write-Host 'Installed = matching installed program and its version: same/older => this installer is redundant; NEWER => it may be a pending update; empty => not installed (ask whether the user still plans to install it); "publisher only" => only the vendor matched, NOT evidence that this product is installed - check by hand.'
