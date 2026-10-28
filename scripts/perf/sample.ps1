# Samples the klepsydra.exe at -Path (the installed one, say) and its own WebView2 tree: the
# browser process it started and that browser's children. One CSV row per
# process per sample: memory in MB and CPU seconds used so far.
param([Parameter(Mandatory)] [string]$Path, [int]$IntervalSec = 180, [double]$DurationMin = 600, [string]$Out = (Join-Path $env:USERPROFILE "klepsydra-perf\samples.csv"))
New-Item -ItemType Directory -Force -Path (Split-Path $Out) | Out-Null
if (-not (Test-Path $Out)) { "time,pid,role,ws_mb,private_mb,cpu_s" | Out-File -Encoding ascii $Out }
$end = (Get-Date).AddMinutes($DurationMin)
while ((Get-Date) -lt $end) {
  # By path: a test copy or a build run beside the installed app has the same name.
  $exe = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Path } | Select-Object -First 1
  $now = (Get-Date).ToString("s")
  if ($exe) {
    $wv = Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'"
    $browser = $wv | Where-Object { $_.ParentProcessId -eq $exe.Id }
    $ids = @{}; $ids[$exe.Id] = 'exe'
    foreach ($b in $browser) {
      $ids[[int]$b.ProcessId] = 'wv-browser'
      foreach ($c in ($wv | Where-Object { $_.ParentProcessId -eq $b.ProcessId })) {
        $cl = [string]$c.CommandLine; $t = 'other'
        if ($cl -match '--type=([a-z-]+)') { $t = $Matches[1] }
        if ($cl -match '--utility-sub-type=([a-zA-Z]+)\.') { $t = "utility-" + $Matches[1] }
        $ids[[int]$c.ProcessId] = "wv-" + $t
      }
    }
    $lines = foreach ($id in $ids.Keys) {
      $p = Get-Process -Id $id -ErrorAction SilentlyContinue
      if ($p) { "{0},{1},{2},{3},{4},{5}" -f $now,$id,$ids[$id],[math]::Round($p.WorkingSet64/1MB,1),[math]::Round($p.PrivateMemorySize64/1MB,1),[math]::Round($p.TotalProcessorTime.TotalSeconds,3) }
    }
    $lines | Out-File -Append -Encoding ascii $Out
  } else { "$now,0,absent,0,0,0" | Out-File -Append -Encoding ascii $Out }
  Start-Sleep -Seconds $IntervalSec
}
