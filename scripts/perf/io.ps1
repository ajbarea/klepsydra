param([int]$Seconds = 60)
function snap { Get-CimInstance Win32_Process -Filter "Name='klepsydra.exe'" | Select-Object ProcessId, ExecutablePath, ReadOperationCount, ReadTransferCount, OtherOperationCount, KernelModeTime, UserModeTime }
$a = snap; Start-Sleep -Seconds $Seconds; $b = snap
foreach ($x in $a) { $y = $b | Where-Object ProcessId -eq $x.ProcessId
  "{0} {1} reads={2} bytes={3} other={4} cpu_ms={5}" -f $x.ProcessId, $x.ExecutablePath, ($y.ReadOperationCount-$x.ReadOperationCount), ($y.ReadTransferCount-$x.ReadTransferCount), ($y.OtherOperationCount-$x.OtherOperationCount), [math]::Round((($y.KernelModeTime+$y.UserModeTime)-($x.KernelModeTime+$x.UserModeTime))/10000) }
