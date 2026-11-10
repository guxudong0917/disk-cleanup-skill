# Shared helpers, dot-sourced by the other scripts:  . "$PSScriptRoot\WizTreeCsv.ps1"
# WizTree CSV: line 1 = banner, line 2 = (localized) header, then
# "path",size,allocated,modified,attributes,files,folders[,...]   (folder paths end with '\')
#
# PERFORMANCE RULE: a folders scan has ~200k lines, a files scan ~1.3M. PowerShell costs tens of
# microseconds per loop iteration, so NEVER loop over scan lines in PowerShell. All per-line work
# (parsing, size/date/regex filtering, newest-timestamp propagation, scan diffs, tree building)
# happens in the C# class below; PowerShell only handles the few hundred/thousand rows that survive.

if (-not ('WtCsv' -as [type])) {
$wtSource = @"
using System; using System.IO; using System.Collections.Generic; using System.Globalization; using System.Text.RegularExpressions;
public class WtRow { public string Path; public double Size; public double Alloc; public string Modified; }
public class WtDiff { public string Path; public double OldAlloc; public double NewAlloc; public int Depth; }
public class WtNode { public string Path; public double Alloc; public string Mod; public string MaxMod; }

public static class WtCsv {
  static readonly Regex Rx = new Regex("^\"((?:[^\"]|\"\")*)\",(\\d+),(\\d+),([^,]*),", RegexOptions.Compiled);
  static readonly string[] Fmts = { "yyyy/MM/dd HH:mm:ss","yyyy-MM-dd HH:mm:ss","yyyy/M/d H:mm:ss","M/d/yyyy h:mm:ss tt","M/d/yyyy H:mm:ss","d/M/yyyy H:mm:ss","dd.MM.yyyy HH:mm:ss" };
  public static bool TryDate(string s, out DateTime d) {
    if (DateTime.TryParseExact(s, Fmts, CultureInfo.InvariantCulture, DateTimeStyles.None, out d)) return true;
    return DateTime.TryParse(s, out d);
  }
  static bool Parse(string line, out WtRow r) {
    r = null; var m = Rx.Match(line); if (!m.Success) return false;
    r = new WtRow { Path = m.Groups[1].Value.Replace("\"\"", "\""), Size = double.Parse(m.Groups[2].Value),
                    Alloc = double.Parse(m.Groups[3].Value), Modified = m.Groups[4].Value };
    return true;
  }
  // kind: 0 = all, 1 = folders only, 2 = files only. lineFilter may be null. after: DateTime.MinValue = no date filter.
  public static List<WtRow> Read(string csv, Regex lineFilter, double minAlloc, int kind, DateTime after) {
    var res = new List<WtRow>();
    foreach (var line in File.ReadLines(csv)) {
      if (lineFilter != null && !lineFilter.IsMatch(line)) continue;
      WtRow r; if (!Parse(line, out r)) continue;
      if (r.Alloc < minAlloc) continue;
      bool isFolder = r.Path.EndsWith("\\");
      if ((kind == 1 && !isFolder) || (kind == 2 && isFolder)) continue;
      if (after > DateTime.MinValue) { DateTime d; if (!TryDate(r.Modified, out d) || d < after) continue; }
      res.Add(r);
    }
    return res;
  }
  // For every folder that is a DIRECT CHILD of one of roots: newest Modified among it and all its descendants.
  public static Dictionary<string, string> LatestUnder(string csv, string[] roots) {
    var res = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    var best = new Dictionary<string, DateTime>(StringComparer.OrdinalIgnoreCase);
    foreach (var line in File.ReadLines(csv)) {
      if (line.Length < 4 || line[0] != '"') continue;
      string root = null;
      foreach (var r0 in roots) { if (string.Compare(line, 1, r0, 0, r0.Length, StringComparison.OrdinalIgnoreCase) == 0) { root = r0; break; } }
      if (root == null) continue;
      WtRow r; if (!Parse(line, out r)) continue;
      int i = r.Path.IndexOf('\\', root.Length); if (i < 0) continue;      // a file directly in root
      string key = r.Path.Substring(0, i + 1);
      DateTime d; if (!TryDate(r.Modified, out d)) continue;
      DateTime cur; if (!best.TryGetValue(key, out cur) || d > cur) { best[key] = d; res[key] = r.Modified; }
    }
    return res;
  }
  // Folder sizes in two scans up to maxDepth (0 = drive root). Missing on one side = 0.
  public static List<WtDiff> Compare(string oldCsv, string newCsv, int maxDepth) {
    var a = Folders(oldCsv, maxDepth); var b = Folders(newCsv, maxDepth);
    var res = new List<WtDiff>();
    foreach (var kv in b) { WtRow o; a.TryGetValue(kv.Key, out o); res.Add(new WtDiff { Path = kv.Value.Path, OldAlloc = o == null ? 0 : o.Alloc, NewAlloc = kv.Value.Alloc, Depth = Depth(kv.Value.Path) }); }
    foreach (var kv in a) { if (!b.ContainsKey(kv.Key)) res.Add(new WtDiff { Path = kv.Value.Path, OldAlloc = kv.Value.Alloc, NewAlloc = 0, Depth = Depth(kv.Value.Path) }); }
    return res;
  }
  public static int Depth(string p) { int n = 0; var t = p.TrimEnd('\\'); foreach (var c in t) if (c == '\\') n++; return n; }
  static Dictionary<string, WtRow> Folders(string csv, int maxDepth) {
    var d = new Dictionary<string, WtRow>(StringComparer.OrdinalIgnoreCase);
    foreach (var line in File.ReadLines(csv)) {
      int q = line.IndexOf("\\\",", StringComparison.Ordinal); if (q < 0) continue;   // folders only: path ends with \"
      int slashes = 0; for (int i = 1; i < q; i++) if (line[i] == '\\') { slashes++; if (slashes > maxDepth) break; }
      if (slashes > maxDepth) continue;
      WtRow r; if (Parse(line, out r)) d[r.Path] = r;
    }
    return d;
  }
}

public static class WtTree {
  public static Dictionary<string, WtNode> Nodes;
  public static Dictionary<string, List<WtNode>> Kids;
  // Loads a folders scan; MaxMod = newest timestamp in the subtree (string compare: needs yyyy/MM/dd HH:mm:ss dates).
  // NOTE: WizTree's "Modified" for a FOLDER is already the newest modification of anything inside it, not the
  // folder's own NTFS timestamp (verified: folder LastWriteTime 11/07, newest file inside 11/09, export says 11/09).
  // So editing an existing file deep inside a project does make the project "active" - no files scan needed.
  public static void Load(string csv) {
    var rx = new Regex("^\"((?:[^\"]|\"\")*\\\\)\",(\\d+),(\\d+),([^,]*),", RegexOptions.Compiled);
    var d = new Dictionary<string, WtNode>(StringComparer.OrdinalIgnoreCase);
    foreach (var line in File.ReadLines(csv)) {
      var m = rx.Match(line); if (!m.Success) continue;
      var p = m.Groups[1].Value.Replace("\"\"", "\"");
      d[p] = new WtNode { Path = p, Alloc = double.Parse(m.Groups[3].Value), Mod = m.Groups[4].Value, MaxMod = m.Groups[4].Value };
    }
    var kids = new Dictionary<string, List<WtNode>>(StringComparer.OrdinalIgnoreCase);
    foreach (var n in d.Values) {
      int i = n.Path.LastIndexOf('\\', n.Path.Length - 2); if (i < 0) continue;
      var par = n.Path.Substring(0, i + 1);
      List<WtNode> l; if (!kids.TryGetValue(par, out l)) { l = new List<WtNode>(); kids[par] = l; } l.Add(n);
      string p2 = n.Path;
      while (true) {
        int j = p2.LastIndexOf('\\', p2.Length - 2); if (j < 0) break;
        p2 = p2.Substring(0, j + 1);
        WtNode a; if (!d.TryGetValue(p2, out a)) break;
        if (string.CompareOrdinal(n.Mod, a.MaxMod) > 0) a.MaxMod = n.Mod;
      }
    }
    Nodes = d; Kids = kids;
  }
  static readonly HashSet<string> NoDescend = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
    "node_modules","Library",".venv","venv","Intermediate","site-packages",".git","DerivedDataCache","Saved","__pycache__",".gradle","obj","Temp","Media Cache Files","Peak Files",
    ".pnpm-store",".pnpm-store-main","pnpm-store",".yarn","User Data","Packages","AppData" };   // package stores / browser profiles: never touch parts of them
  public static List<WtNode> Walk(string[] roots) {
    var res = new List<WtNode>(); var st = new Stack<string>(roots);
    while (st.Count > 0) {
      var p = st.Pop(); List<WtNode> l; if (!Kids.TryGetValue(p, out l)) continue;
      foreach (var c in l) {
        res.Add(c);
        var leaf = c.Path.TrimEnd('\\'); leaf = leaf.Substring(leaf.LastIndexOf('\\') + 1);
        if (!NoDescend.Contains(leaf)) st.Push(c.Path);
      }
    }
    return res;
  }
  // Nodes under roots that have at least one marker child folder (cheap pre-filter for project detection).
  public static List<WtNode> Candidates(string[] roots, string[] markers) {
    var res = new List<WtNode>();
    foreach (var c in Walk(roots)) {
      foreach (var m in markers) { if (Nodes.ContainsKey(c.Path + m + "\\")) { res.Add(c); break; } }
    }
    return res;
  }
}
"@
# Add-Type compiles through %TEMP%. In a sandboxed agent (or a locked-down account) TEMP may not be writable:
# retry with another writable folder, and if it still fails STOP with exit code 2. Never continue without the
# reader - every script would then print "0 files, 0.00 GB" / empty tables and exit 0, which reads as "nothing to clean".
$wtErr = $null
foreach ($tmp in @($env:TEMP, (Join-Path $PSScriptRoot '..\.tmp'), (Join-Path $env:LOCALAPPDATA 'Temp\disk-cleanup'), (Join-Path $env:USERPROFILE '.disk-cleanup\tmp'))) {
  if (-not $tmp) { continue }
  try {
    if (-not (Test-Path -LiteralPath $tmp)) { New-Item -ItemType Directory -Path $tmp -Force -ErrorAction Stop | Out-Null }
    $oldT = $env:TEMP; $oldTmp = $env:TMP; $env:TEMP = $tmp; $env:TMP = $tmp
    try { Add-Type -TypeDefinition $wtSource -ErrorAction Stop; $wtErr = $null; break } finally { $env:TEMP = $oldT; $env:TMP = $oldTmp }
  } catch { $wtErr = $_.Exception.Message }
}
if (-not ('WtCsv' -as [type])) {
  Write-Host "FATAL: cannot compile the snapshot reader (WizTreeCsv.ps1): $wtErr"
  Write-Host 'No snapshot-based result is valid in this run. Typical cause: a sandboxed agent account with no writable TEMP - run outside the sandbox.'
  exit 2
}
}

. "$PSScriptRoot\Config.ps1"
function Get-DefaultScanDir {
  if ($script:DiskCleanupConfig.ScanDir -and (Test-Path -LiteralPath $script:DiskCleanupConfig.ScanDir)) { return $script:DiskCleanupConfig.ScanDir }
  $sys = $env:SystemDrive.TrimEnd(':').ToUpper()
  $other = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Name -ne $sys -and $_.Root -match '^[A-Z]:\\$' } | Sort-Object Name
  foreach ($d in $other) { $p = "$($d.Name):\WizTreeScans"; if (Test-Path -LiteralPath $p) { return $p } }
  $p = Join-Path $env:USERPROFILE 'WizTreeScans'
  if (Test-Path -LiteralPath $p) { return $p }
  return $null
}

function Get-LatestScan([string]$Drive = 'C', [string]$Mode = 'folders', [int]$Skip = 0) {
  $dir = Get-DefaultScanDir
  if (-not $dir) { throw 'No WizTreeScans folder found. Run Invoke-WizTreeScan.ps1 first.' }
  $f = Get-ChildItem -LiteralPath $dir -Filter "$($Drive.TrimEnd(':'))_${Mode}_*.csv" | Sort-Object LastWriteTime -Descending | Select-Object -Skip $Skip -First 1
  if (-not $f) { throw "No $Mode scan of ${Drive}: in $dir (skip=$Skip). Run Invoke-WizTreeScan.ps1 -Mode $Mode." }
  return $f.FullName
}

function ConvertTo-ScanDate([string]$s) {
  $d = [datetime]::MinValue
  if ([WtCsv]::TryDate($s, [ref]$d)) { return $d }
  return $null
}

# Regex for raw lines whose path is a direct child folder of one of $Parents (each ending with '\').
function New-ChildFolderRegex([string[]]$Parents) {
  $alt = ($Parents | ForEach-Object { [regex]::Escape($_) }) -join '|'
  return [regex]::new('^"(?:' + $alt + ')[^\\"]+\\",', 'IgnoreCase')
}

# Rows (WtRow: Path, Size, Alloc, Modified) filtered in C#. -Kind 0 all / 1 folders / 2 files; -After: modified on/after.
function Read-WizTreeCsv([string]$Csv, [regex]$LineRegex, [double]$MinAlloc = 0, [int]$Kind = 0, [datetime]$After = [datetime]::MinValue) {
  return [WtCsv]::Read($Csv, $LineRegex, $MinAlloc, $Kind, $After)
}

function Get-PathDepth([string]$p) { return [WtCsv]::Depth($p) }

# Is a zip really the same as an extracted folder? Equal total size proves nothing (seen: same-size course
# archive where two files inside differed from the extracted copies). Compares entry by entry: relative path
# (also tried with the folder name stripped, for zips that contain a top folder), size, and with -Hash the
# SHA256 of every pair of same-size files. Verdict: identical / differs / folder-has-more (edited or added after
# extraction: keep the archive unless the user decides) / partial (entries missing from the folder).
function Compare-ArchiveFolder([string]$Archive, [string]$Folder, [switch]$Hash, [int]$Show = 10) {
  $folder = (Resolve-Path -LiteralPath $Folder).Path.TrimEnd('\') + '\'
  $files = @{}; Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $files[$_.FullName.Substring($folder.Length).ToLower()] = $_ }
  $z = Open-ZipArchive $Archive
  try {
    $entries = @($z.Entries | Where-Object { $_.FullName -notmatch '[/\\]$' })
    $top = $entries | ForEach-Object { ($_.FullName -split '[/\\]')[0] } | Select-Object -Unique
    $strip = if (@($top).Count -eq 1 -and $entries.Count -gt 0 -and ($entries | Where-Object { $_.FullName -match '[/\\]' }).Count -eq $entries.Count) { $top + '/' } else { '' }
    $missing = @(); $diff = @(); $same = 0; $matched = @{}
    foreach ($e in $entries) {
      $rel = ($e.FullName -replace '/', '\').ToLower()
      $f = $files[$rel]; if (-not $f -and $strip) { $rel = ($e.FullName.Substring($strip.Length) -replace '/', '\').ToLower(); $f = $files[$rel] }
      if (-not $f) { $missing += $e.FullName; continue }
      $matched[$rel] = 1
      if ($f.Length -ne $e.Length) { $diff += "$($e.FullName) (size $($e.Length) vs $($f.Length))"; continue }
      if ($Hash) {
        $sha = [Security.Cryptography.SHA256]::Create(); $st = $e.Open()
        try { $h1 = [BitConverter]::ToString($sha.ComputeHash($st)) -replace '-','' } finally { $st.Dispose(); $sha.Dispose() }
        if ($h1 -ne (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash) { $diff += "$($e.FullName) (same size, different content)"; continue }
      }
      $same++
    }
    $extra = @($files.Keys | Where-Object { -not $matched.ContainsKey($_) })
    $verdict = if ($diff) { 'differs' } elseif ($missing) { 'partial' } elseif ($extra) { 'folder-has-more' } else { 'identical' }
    [pscustomobject]@{ Verdict = $verdict; Checked = $(if ($Hash) { 'path+size+SHA256' } else { 'path+size only (use -Hash before deleting)' })
      Entries = $entries.Count; Same = $same; Differ = $diff.Count; MissingInFolder = $missing.Count; ExtraInFolder = $extra.Count
      DifferList = ($diff | Select-Object -First $Show) -join '; '; MissingList = ($missing | Select-Object -First $Show) -join '; '; ExtraList = ($extra | Select-Object -First $Show) -join '; ' }
  } finally { $z.Dispose() }
}

# Free/total space per fixed drive. Get-PSDrive returns Free/Used = 0 and Win32_LogicalDisk fails in some
# sandboxed or restricted contexts: try DriveInfo, then CIM, and mark a drive "unreadable" instead of
# reporting 0 GB free (which reads as "the disk is full").
function Get-DriveSpace {
  foreach ($d in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' }) {
    $free = $null; $total = $null; $src = 'DriveInfo'
    try { if ($d.IsReady) { $free = $d.AvailableFreeSpace; $total = $d.TotalSize } } catch {}
    if (-not $total) {
      $src = 'CIM'
      try { $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($d.Name.Substring(0,2))'" -ErrorAction Stop; $free = $c.FreeSpace; $total = $c.Size } catch {}
    }
    if ($total) { [pscustomobject]@{ Drive = $d.Name.Substring(0,1); FreeGB = [math]::Round($free/1GB,2); TotalGB = [math]::Round($total/1GB,1); Source = $src } }
    else { [pscustomobject]@{ Drive = $d.Name.Substring(0,1); FreeGB = 'unreadable'; TotalGB = 'unreadable'; Source = 'none' } }
  }
}

# Open a zip for reading with readable entry names. Entries without the UTF-8 flag (most zips made by Chinese,
# Japanese, Korean... Windows tools) are stored in a legacy code page; .NET decodes them with the system ANSI
# code page, which is wrong when the system runs with "Beta: Use Unicode UTF-8" or another locale, and every
# name comparison/hash lookup then fails. Tries: -CodePage, config "ZipCodePages" (e.g. [936]), then UTF-8 /
# system default, then 936, 950, 932, 949; picks the first that decodes every name without U+FFFD.
# Caller disposes: $z = Open-ZipArchive x.zip; try { $z.Entries } finally { $z.Dispose() }
function Open-ZipArchive([string]$Path, [int[]]$CodePage) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $cands = @()
  if ($CodePage) { $cands += $CodePage }
  if ($script:DiskCleanupConfig.ZipCodePages) { $cands += @($script:DiskCleanupConfig.ZipCodePages | ForEach-Object { [int]$_ }) }
  $cands += 0, 936, 950, 932, 949
  foreach ($cp in ($cands | Select-Object -Unique)) {
    $enc = if ($cp -eq 0) { $null } else { try { [Text.Encoding]::GetEncoding($cp) } catch { continue } }
    $z = [IO.Compression.ZipFile]::Open($Path, 'Read', $enc)
    if (-not ($z.Entries | Where-Object { $_.FullName.Contains([char]0xFFFD) } | Select-Object -First 1)) { return $z }
    $z.Dispose()
  }
  return [IO.Compression.ZipFile]::OpenRead($Path)
}
