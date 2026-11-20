# IMPL: klepsydra#423, the heavy lock as a pool sized from the machine it runs on

HOLD (Heph 11-20): do not start until the Personal weekly reset, Mon 11-23 1 PM.
Branch perf/heavylock (worktree .claude/worktrees/perf-heavylock, from origin/main). No PR yet.
Push only: `git push -u origin perf/heavylock:perf/heavylock`. Never push to main. Athena reviews and merges.
Spec: the issue body plus AJ's 11-20 comment (size from the enclosing cgroup's memory.max/cpu.max, the
affinity CPUs, PSI admission, per-target weights from memory.peak; no constant tuned to this PC).

## Facts found (11-20, perf-k)
- `fleet/heavy.sh` (80 lines) is one global flock on /tmp/fleet-heavy.lock, with holder detection, the
  caller-holds refusal, the process-group timeout kill and signal forwarding. Tests: fleet/test_heavy_lock.sh,
  doctor's holder check (doctor.sh:546).
- Nearly every heavy run bypasses heavy.sh: `fleet/brief-tail.md` tells agents to run raw
  `flock -o /tmp/fleet-heavy.lock CMD`; headless-rules.md says `-w 420`. So the pool must treat
  /tmp/fleet-heavy.lock as slot 0 (raw callers keep working, serialised among themselves), and the brief
  must move to the pool command, or the pool never fills.
- lib.sh already walks the cgroup chain for pids.max (`fleet_tasks_max`), has `to_mib`, `mem_total_mib`,
  `cgroup_kept_mib`, `proc_cgroup`; but lib.sh forks at source time (FLEET_HEPH_ACCOUNTS), so heavy.sh must
  not source it. Put the probe in a small builtin-only file (`fleet/capacity.sh`) that heavy.sh, doctor and
  lib.sh all source (DRY: move the chain walk there, fleet_tasks_max uses it).
- Constants AJ named: MEM_MAX=5G, MEM_SWAP=1G (launch.sh), FLEET_MIN_AVAIL_MB=3000 (delegate.sh:534),
  FLEET_SLICE_BASE_MB=847 (lib.sh:821, measured once on this PC). Deriving those is a second PR, same probe.

## Design (research: sources at the end)
1. Probe, builtins only, once per heavy.sh call: own cgroup from /proc/self/cgroup; walk every ancestor to
   the root and take the tightest memory.max (limit) and the least `memory.max - memory.current` (room); at
   the root, MemTotal / MemAvailable. CPUs = min(Cpus_allowed_list count, ceil(quota/period) of every
   cpu.max on the chain). PSI from the tightest level's memory.pressure / cpu.pressure, else /proc/pressure.
2. Slots: lock files slot 0 = /tmp/fleet-heavy.lock, slot i = /tmp/fleet-heavy.lock.i. A gate lock
   (/tmp/fleet-heavy.lock.gate) queues waiters in order; the gate holder takes the first free slot whose
   admission passes, starts the run, releases the gate. Admission: room >= weight(target) + margin, and
   memory and CPU PSI some avg10 under a ratio threshold. No slot count constant: slots are bounded by
   floor(limit / smallest known weight) and CPUs.
3. Weight: each run in its own transient scope under fleet.slice (`systemd-run --user --scope
   --slice=fleet-heavy.slice`, still under the fleet cap) so its memory.peak is its own; record
   "target peak_mb waited_s ran_s rc" per run in $FLEET_STATE/heavy.log (target = the command's words up to
   the first path). Weight = max of the last N peaks of that target; unknown target = the largest known.
   No systemd (Slurm nodes): run in place, weight from history only.
4. Keep every existing guarantee (issue body list) and the doctor holder check, extended to N slots.
5. Brief: `fleet/brief-tail.md` and headless-rules.md move to the pool command (`fleet heavy CMD`).

## Next
1. ✅ Before data (11-20, 1 h, live fleet, `sample.sh` -> before.csv, `summary.py`): 333 samples; lock held
   78%; a waiter present 38%; in all 127 waiting samples room (min of slice headroom, MemAvailable) was
   >= 2,048 MiB (median 2,878) and memory PSI some10 was 0.00; cpu PSI some10 median 2.79, max 18.84.
   So a second slot would have been admitted every time someone waited.
2. Web-search the PSI admission threshold (systemd-oomd defaults, Meta's oomd/senpai guidance) and the
   systemd-run --scope cost; settle thresholds from before.csv, with citations.
3. Open the PR (label performance, assignee ajbarea, Closes #423) when the first code lands.
4. Guards: fake cgroup tree (8 GB node, 64 GB node, Slurm-style 4 GB memory.max inside a 512 GB node),
   slot counts each gives; a mutation reading /proc/meminfo instead fails the Slurm case; fork budget:
   the probe starts no process (strace, fleet/test_forks_*.sh pattern, strace 6.8 now installed).
5. After data: same sampler with the pool live.

## Sources
- Kernel PSI (per-cgroup pressure files, triggers): https://docs.kernel.org/accounting/psi.html
- systemd PRESSURE (MemoryPressureWatch): https://systemd.io/PRESSURE
- Nested cgroup limits must be walked up the chain (JVM read only one level): https://bugs.openjdk.org/browse/JDK-8322420
- cgroup v2 interface files: https://docs.kernel.org/admin-guide/cgroup-v2.html
- GNU make job slots (token pool): https://www.gnu.org/software/make/manual/html_node/Job-Slots.html
