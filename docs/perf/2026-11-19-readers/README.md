<!-- budget: 500 words -->
# Reading only the files that changed (#501)

## Live baseline

The installed `klepsydra.exe` (main as deployed on 11-19) was sampled for 60 s at about 18:25 with
`scripts/perf/io.ps1`, which reads the process's Windows I/O counters (`Win32_Process`) before and
after. The live fleet was running and the wall was open.

| Counter, 60 s | Value |
|---|---:|
| read operations | 16,231 |
| other operations (opens, queries, closes, listings) | 34,991 |
| bytes read | 3,227,986 |
| CPU (kernel + user) | 1,422 ms |

## Per call, on the real data

`src-tauri/fleet/examples/readcost.rs` calls each reader once to warm up, then 100 times, and reads
`GetProcessIoCounters` around the 100 calls. It ran natively on Windows (release build, NTFS stage)
against a copy of the live data folder: 70 session files and 47 heartbeats in `fleet/`, and 70
readings in 3 account folders in `accounts/`. Before is origin/main 5dfdff5. After is this branch.
There were three alternating runs (`ab.txt`). The counts were identical in every run. Times are the
median of the three run medians, with the range.

| Reader, per call | Before | After |
|---|---|---|
| fleet scan: reads / other ops / bytes | 234 / 711 / 100,355 | 0 / 9 / 0 |
| fleet scan: time | 9.40 ms (9.04 to 10.08) | 0.63 ms (0.62 to 0.68) |
| usage readings: reads / other ops / bytes | 426 / 593 / 22,511 | 0 / 25 / 0 |
| usage readings: time | 8.46 ms (8.25 to 9.66) | 0.57 ms (0.56 to 0.59) |
| fleet reader step: reads / other ops | 234 / 768 | 0 / 66 |
| fleet reader step: time | 10.24 ms (9.53 to 10.59) | 1.29 ms (1.27 to 1.42) |

The fleet reader steps on every change in `fleet/` and every 5 s. The usage readings are read every
5 s by the gauge and every 5 s by the phone server, and once per launch.

The remaining 57 other operations in a step (66 minus the scan's 9) come from the per-session checks
after the scan: each session's reply clip (two queries), the wrap-up files and keryx's speaking file.

## Not measured here

The installed app after the change: it is measured with `scripts/perf/io.ps1` once a build with
this change is deployed.
