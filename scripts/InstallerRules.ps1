# Shared "does this file NAME look like an installer" rule, dot-sourced by Find-OldFiles.ps1 and
# Test-Installer.ps1 so both scripts flag the same candidates (they used to differ, and a model that
# only trusted Find-OldFiles missed names like SomeApp-win32-x64-user-5.9.3.exe / AppName_7.27.0.5.exe).
#   package      .msi .msix .msixbundle .appx .iso .apk          -> installer by definition
#   setup-name   setup / install / installer / update / upgrade / "an zhuang" (Chinese) in an .exe name,
#                or a browser-duplicate download like x.exe.1
#   version-name .exe whose name carries a version or platform tag (Git-2.54.0-64-bit.exe,
#                SunloginClient_15.3.2_x64.exe, letsvpn-latest.exe) -> likely an installer, verify with Test-Installer
$script:ZhInstall = [string][char]0x5B89 + [char]0x88C5
$script:PkgRx     = [regex]'(?i)\.(msi|msix|msixbundle|appx|appxbundle|iso|apk)$'
$script:SetupRx   = [regex]("(?i)((setup|install|installer|update|upgrade|$($script:ZhInstall))[^\\]*\.exe$)|(\.exe\.\d+$)")
$script:VersionRx = [regex]'(?i)([-_ .]v?\d+(\.\d+){1,3}|[-_ ](x64|x86_64|win64|amd64|win32|64-?bit)|-latest)[^\\]*\.exe$'

function Get-InstallerNameKind([string]$name) {
  if ($script:PkgRx.IsMatch($name))     { return 'package' }
  if ($script:SetupRx.IsMatch($name))   { return 'setup-name' }
  if ($script:VersionRx.IsMatch($name)) { return 'version-name' }
  return $null
}
