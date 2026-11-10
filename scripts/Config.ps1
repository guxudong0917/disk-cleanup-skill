# Machine-specific settings live OUTSIDE the skill so the skill itself stays generic and shareable.
#   %USERPROFILE%\.disk-cleanup\config.json   (or the path in $env:DISK_CLEANUP_CONFIG)
# Example:
#   { "ScanDir": "D:\\WizTreeScans", "WizTreePath": "D:\\Tools\\WizTree\\WizTree64.exe", "Keep": 3, "ZipCodePages": [936] }
# ZipCodePages: legacy code pages tried first for zip entry names without the UTF-8 flag
#   (936 Simplified Chinese GBK, 950 Traditional Chinese, 932 Japanese, 949 Korean, 1251 Cyrillic ...).
# Every field is optional; scripts fall back to auto-detection when a field is missing.
function Get-DiskCleanupConfig {
  $p = if ($env:DISK_CLEANUP_CONFIG) { $env:DISK_CLEANUP_CONFIG } else { Join-Path $env:USERPROFILE '.disk-cleanup\config.json' }
  if (Test-Path -LiteralPath $p) {
    try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { Write-Host "WARN: cannot parse $p : $($_.Exception.Message)" }
  }
  return [pscustomobject]@{}
}
$script:DiskCleanupConfig = Get-DiskCleanupConfig
