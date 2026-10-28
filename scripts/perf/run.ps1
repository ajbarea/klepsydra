# One controlled performance run on Windows: a klepsydra build (-Build, its
# klepsydra.exe run where it was built) with its own data folder, its own
# WebView2 user data folder and a DevTools port, fed the demo fleet in
# <Root>\run-<N> (scripts/perf/fixture.py). Prints one JSON line per reading.
# docs/perf/2026-10-28/README.md says what each reading is.
#
# Run scripts/perf/fixture.py for each N first, into <Root>\run-<N>, and copy
# this folder's cdp.mjs beside this script.
#
# The build must honour KLEPSYDRA_NO_AUTOSTART (#142 and later): the run reads
# the login entry before and 30 s after each start and stops the copy and
# fails at once if it changed, never writing it back. (A copy without the
# switch re-registered the entry with its own path, the harness wrote it
# back, and Defender read the pair as persistence malware.)
param(
  [string]$Cards = "0,3,6,10",  # comma-separated: -File passes one string
  [string]$Root = (Join-Path $env:USERPROFILE "klepsydra-perf"),
  [Parameter(Mandatory)] [string]$Build,
  [int]$IdleSec = 120,
  [int]$Reps = 5,
  [int]$Port = 9333
)
$ErrorActionPreference = "Stop"
$exe = $Build
$started = @()  # Process objects: their handles keep a reused PID from being mistaken for them
$cdp = Join-Path $PSScriptRoot "cdp.mjs"
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$before = (Get-ItemProperty $runKey -ErrorAction SilentlyContinue).klepsydra

Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class Win {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static IntPtr Find(uint pid, string title) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); var s = new StringBuilder(256); GetWindowText(h, s, 256);
      if (p == pid && s.ToString() == title) { found = h; return false; } return true; }, IntPtr.Zero);
    return found;
  }
}
"@

function Tree($root) {
  $wv = Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'"
  $ids = @{}; $ids[[int]$root.Id] = 'exe'
  foreach ($b in ($wv | Where-Object { $_.ParentProcessId -eq $root.Id })) {
    $ids[[int]$b.ProcessId] = 'wv-browser'
    foreach ($c in ($wv | Where-Object { $_.ParentProcessId -eq $b.ProcessId })) {
      $cl = [string]$c.CommandLine; $t = 'other'
      if ($cl -match '--type=([a-z-]+)') { $t = $Matches[1] }
      if ($cl -match '--utility-sub-type=([a-zA-Z]+)\.') { $t = "utility-" + $Matches[1] }
      $ids[[int]$c.ProcessId] = "wv-" + $t
    }
  }
  $ids
}
function Snap($ids) {
  $out = @{}
  foreach ($id in $ids.Keys) {
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($p) { $out[$id] = @{ role = $ids[$id]; cpu = $p.TotalProcessorTime.TotalSeconds; ws = $p.WorkingSet64; priv = $p.PrivateMemorySize64 } }
  }
  $out
}
# CPU as percent of one core over the span, memory at its end, per role
# (renderers summed) and in total.
function Idle($proc, $label, $seconds) {
  $ids = Tree $proc
  $a = Snap $ids; $t0 = Get-Date
  Start-Sleep -Seconds $seconds
  $b = Snap $ids; $span = ((Get-Date) - $t0).TotalSeconds
  $roles = @{}
  foreach ($id in $b.Keys) {
    if (-not $a.ContainsKey($id)) { continue }
    $r = $b[$id].role
    if (-not $roles.ContainsKey($r)) { $roles[$r] = @{ cpu_pct = 0.0; ws_mb = 0.0; private_mb = 0.0; n = 0 } }
    $roles[$r].cpu_pct += ($b[$id].cpu - $a[$id].cpu) / $span * 100
    $roles[$r].ws_mb += $b[$id].ws / 1MB; $roles[$r].private_mb += $b[$id].priv / 1MB; $roles[$r].n++
  }
  $tot = @{ cpu_pct = 0.0; ws_mb = 0.0; private_mb = 0.0 }
  foreach ($r in @($roles.Keys)) {
    foreach ($k in @('cpu_pct', 'ws_mb', 'private_mb')) { $roles[$r][$k] = [math]::Round($roles[$r][$k], 2); $tot[$k] += $roles[$r][$k] }
  }
  foreach ($k in @($tot.Keys)) { $tot[$k] = [math]::Round($tot[$k], 2) }
  [ordered]@{ reading = $label; seconds = [math]::Round($span); total = $tot; roles = $roles } | ConvertTo-Json -Compress -Depth 5
}
function Cdp {
  & node $cdp $Port @args
  if ($LASTEXITCODE -ne 0) { [ordered]@{ cdp_failed = ($args -join " "); exit = $LASTEXITCODE } | ConvertTo-Json -Compress }
}

try {
  foreach ($n in ($Cards -split "," | ForEach-Object { [int]$_ })) {
    $dir = Join-Path $Root "run-$n"
    $env:KLEPSYDRA_DIR = $dir
    $env:KLEPSYDRA_NO_AUTOSTART = "1"
    $env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $dir "EBWebView"
    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$Port"
    $proc = Start-Process $exe -PassThru
    $started += $proc
    Start-Sleep -Seconds 30
    if ((Get-ItemProperty $runKey -ErrorAction SilentlyContinue).klepsydra -ne $before) {
      throw "the login entry changed after starting $exe; is it a build with KLEPSYDRA_NO_AUTOSTART (#142)? Stopped; nothing written back"
    }
    [ordered]@{ cards = $n; pid = $proc.Id; targets = (Cdp targets) } | ConvertTo-Json -Compress
    Idle $proc "cards=$n gauge only" $IdleSec
    Cdp idle gauge 60
    if ($n -gt 0) {
      Cdp openwall gauge
      Start-Sleep -Seconds 15
      [ordered]@{ wall_open = [bool]((Cdp targets) -match 'wall.html') } | ConvertTo-Json -Compress
      Idle $proc "cards=$n wall shown" $IdleSec
      Cdp idle wall 60
      for ($i = 0; $i -lt $Reps; $i++) { Cdp cold wall $n; Start-Sleep -Seconds 3 }
      $file = (Get-ChildItem (Join-Path $dir "fleet") -Filter *.json | Select-Object -First 1).FullName
      for ($i = 0; $i -lt $Reps; $i++) { Cdp update wall $file }
      $h = [Win]::Find([uint32]$proc.Id, "klepsydra fleet")
      if ($h -eq [IntPtr]::Zero) { throw "no wall window for pid $($proc.Id)" }
      [void][Win]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)  # WM_CLOSE: the wall hides
      Start-Sleep -Seconds 10
      [ordered]@{ wall_visible_after_close = [Win]::IsWindowVisible($h) } | ConvertTo-Json -Compress
      Idle $proc "cards=$n wall hidden" $IdleSec
      Cdp idle wall 60
    }
    $proc.Kill(); $proc.WaitForExit(10000) | Out-Null
    Start-Sleep -Seconds 5
  }
} finally {
  foreach ($p in $started) { if (-not $p.HasExited) { $p.Kill() } }
  $after = (Get-ItemProperty $runKey -ErrorAction SilentlyContinue).klepsydra
  [ordered]@{ login_entry_unchanged = ($after -eq $before) } | ConvertTo-Json -Compress
}
