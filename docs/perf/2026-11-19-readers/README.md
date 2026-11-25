<!-- budget: 700 words -->
# Reading only the files that changed (#501)

The tables below are printed by `tables.py` from `ab.txt` and `appab.txt`.
Before is origin/main 5dfdff5. After is this branch at 3d55f66.

## The whole app

`appab.ps1` starts each build in turn on a fresh copy of the live data folder
(`C:\Users\ajbar\klepsydra-perf\data-1119`: 70 session files, 47 heartbeats, 70 readings in
3 account folders). Each run has its own `KLEPSYDRA_DIR` and WebView2 folder and leaves the
login entry alone. After 30 s of warm-up the script reads that process's Windows I/O counters
(`Win32_Process`) over 60 s: three alternating rounds of release builds, gauge shown, wall
closed. Nothing writes to the copy during a run, so these are idle steady-state figures.

| Whole app, 60 s idle (median of 3, range) | Before | After |
|---|---:|---:|
| read operations | 8,036 (8,032 to 8,040) | 118 (112 to 118) |
| other operations | 16,818 | 1,506 |
| bytes read | 1,480,280 (1,479,832 to 1,480,728) | 6,112 (5,440 to 6,112) |
| CPU, ms | 500 (484 to 594) | 281 (125 to 328) |

For scale: the installed app (main as deployed on 11-19), sampled for 60 s with
`scripts/perf/io.ps1` while the live fleet ran and the wall was open, did 16,231 read
operations, 34,991 other operations, 3,227,986 bytes read and 1,422 ms CPU.

## Per call

`src-tauri/fleet/examples/readcost.rs` warms each reader up, then reads
`GetProcessIoCounters` around 100 calls, natively on Windows on the same data copy (`ab.sh`,
three alternating runs). Counts were the same in every run; times are the median of the run
medians, with their range.

| Reader, per call | Before | After |
|---|---|---|
| scan: reads / other ops / bytes | 234 / 711 / 100,355 | 0 / 4 / 0 |
| scan: time | 9.16 ms (9.16 to 9.18) | 0.68 ms (0.67 to 0.72) |
| usage: reads / other ops / bytes | 426 / 593 / 22,511 | 0 / 20 / 0 |
| usage: time | 8.47 ms (8.46 to 8.51) | 0.65 ms (0.56 to 0.73) |
| reader step: reads / other ops / bytes | 234 / 768 / 100,355 | 0 / 61 / 0 |
| reader step: time | 9.56 ms (9.33 to 9.86) | 1.35 ms (1.26 to 1.59) |

The fleet reader steps on every change in `fleet/` and every 5 s; the gauge and the phone
server each read the usage readings every 5 s. On Windows a listing is one directory query
(`FileIdBothDirectoryInfo`) that returns every entry's stamp.

## Not measured here

The installed app after the change on the live fleet, where files are written while it runs:
measured with `scripts/perf/io.ps1` once a build with this change is deployed.

## Leads checked and left as they are

`src-tauri/fleet/examples/phonecost.rs` replays the phone feed on the same data copy (release,
WSL, 300 calls, median). The feed runs only while "Phone wall" is ticked.

| Lead (first-pass audit) | Measured | How often | Kept as is because |
|---|---:|---|---|
| P6: the feed clones and serialises the 24,330-byte snapshot on each usage poll | 0.22 ms | every 5 s | about 0.004% of one core |
| P7: an audio range request parses the whole snapshot | 0.22 ms | 3 to 5 per clip played | about 1 ms per clip |
| A2: gauge and phone each poll usage | 0.65 ms (the shared reader's pass above) | every 5 s | one reader now serves both; a single poller would save 0.65 ms per 5 s |

A1 (the usage readings crossing IPC and reconciled in `src/gauge.js`) belongs to the frontend
pass, which measures it in the webview.

## Mutations

`mutate.py` (Linux, 15 mutations of the shared logic): 14 killed. The survivor is the Unix
inode dropped from the stamp, which is equivalent where a replace moves the ctime the stamp
already holds. `winmutate.sh` (native NTFS, 5 mutations of the Windows listing): 5 killed.
