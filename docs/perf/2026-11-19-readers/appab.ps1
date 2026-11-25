# The whole app before and after #501, on one copy of the live data. Each
# round starts each build in turn on a fresh copy of -Data (its own
# KLEPSYDRA_DIR and WebView2 folder, the login entry untouched), lets it warm
# up, then reads that process's Windows I/O counters over -Seconds. Only the
# processes this script started are stopped. The installed app's
# .window-state.json is restored afterwards. Prints one JSON line per run.
param(
  [Parameter(Mandatory)] [string]$Before,
  [Parameter(Mandatory)] [string]$After,
  [Parameter(Mandatory)] [string]$Data,
  [string]$Root = (Join-Path $env:USERPROFILE "klepsydra-perf\ab-501"),
  [int]$Warm = 30,
  [int]$Seconds = 60,
  [int]$Rounds = 3
)
$ErrorActionPreference = "Stop"
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$login = (Get-ItemProperty $runKey -ErrorAction SilentlyContinue).klepsydra
$state = Join-Path $env:APPDATA "dev.ajsoftworks.klepsydra\.window-state.json"
$saved = if (Test-Path $state) { Get-Content -Raw $state } else { $null }
$started = @()

function Counters([int]$id) {
  $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id"
  [ordered]@{ reads = [int64]$p.ReadOperationCount; bytes = [int64]$p.ReadTransferCount
    other = [int64]$p.OtherOperationCount; cpu = [int64]($p.KernelModeTime + $p.UserModeTime) }
}

try {
  for ($r = 1; $r -le $Rounds; $r++) {
    foreach ($b in @(@{ label = "before"; exe = $Before }, @{ label = "after"; exe = $After })) {
      $dir = Join-Path $Root "$($b.label)-$r"
      if (Test-Path $dir) { Remove-Item -Recurse -Force -LiteralPath $dir }
      New-Item -ItemType Directory -Path $dir | Out-Null
      Copy-Item -Recurse -Path (Join-Path $Data "*") -Destination $dir
      $env:KLEPSYDRA_DIR = $dir
      $env:KLEPSYDRA_NO_AUTOSTART = "1"
      $env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $dir "EBWebView"
      $proc = Start-Process $b.exe -PassThru
      $started += $proc
      Start-Sleep -Seconds $Warm
      if ((Get-ItemProperty $runKey -ErrorAction SilentlyContinue).klepsydra -ne $login) {
        throw "the login entry changed after starting $($b.exe); stopped, nothing written back"
      }
      $x = Counters $proc.Id
      Start-Sleep -Seconds $Seconds
      $y = Counters $proc.Id
      [ordered]@{ build = $b.label; round = $r; pid = $proc.Id; seconds = $Seconds
        reads = $y.reads - $x.reads; other = $y.other - $x.other; bytes = $y.bytes - $x.bytes
        cpu_ms = [math]::Round(($y.cpu - $x.cpu) / 10000) } | ConvertTo-Json -Compress
      $proc.Kill(); $proc.WaitForExit(10000) | Out-Null
      Start-Sleep -Seconds 3
    }
  }
} finally {
  foreach ($p in $started) { if (-not $p.HasExited) { $p.Kill() } }
  if ($null -ne $saved) { Set-Content -NoNewline -Path $state -Value $saved }
  $now = (Get-ItemProperty $runKey -ErrorAction SilentlyContinue).klepsydra
  [ordered]@{ login_entry_unchanged = ($now -eq $login); window_state_restored = ($null -ne $saved) } | ConvertTo-Json -Compress
}
