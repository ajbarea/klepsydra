#!/usr/bin/env bash
# scripts/test_shellcheck.sh: Unit tests for scripts/shellcheck.sh memory guard (#503).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0
fail=0
check() { # NAME GOT WANT
  if [[ "$2" == "$3" ]]; then
    pass=$((pass + 1))
    printf '  ok   %s\n' "$1"
  else
    fail=$((fail + 1))
    printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$3" "$2"
  fi
}

# Stub shellcheck binary for deterministic testing
mkdir -p "$work/bin"
cat >"$work/bin/fake-shellcheck" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ $arg == "--fail" ]] && { echo "fake-error in $arg" >&2; exit 1; }
done
echo "fake-shellcheck checked: $*"
EOF
chmod +x "$work/bin/fake-shellcheck"

runner="$root/scripts/shellcheck.sh"
fake="$work/bin/fake-shellcheck"

# 1. Clean core files run through shellcheck
out=$(SHELLCHECK="$fake" bash "$runner" "$work/a.sh" "$work/b.sh")
check "core files checked" "$out" "fake-shellcheck checked: -x $work/a.sh $work/b.sh"

# 2. Heavy suite file skipped when cgroup memory.max is under 4500 MiB
mkdir -p "$work/cgroup/user.slice"
# 3628 MiB in bytes = 3804233728
echo "3804233728" >"$work/cgroup/user.slice/memory.max"

mkdir -p "$work/proc/self"
echo "0::/user.slice" >"$work/proc/self/cgroup"

mkdir -p "$work/fleet"
touch "$work/fleet/test_fleet.sh"

out=$(SHELLCHECK="$fake" FLEET_CGROUP_ROOT="$work/cgroup" FLEET_PROC="$work/proc" \
  bash "$runner" "$work/fleet/test_fleet.sh")
check "suite skipped when cgroup is constrained" \
  "$(grep -c '^skip .*test_fleet.sh: cgroup memory.max is 3628 MiB' <<<"$out")" "1"

# 3. Heavy suite file skipped when MemAvailable is under 4500 MiB
cat >"$work/meminfo_low" <<'EOF'
MemTotal:        9948000 kB
MemFree:         1000000 kB
MemAvailable:    2000000 kB
EOF

out=$(SHELLCHECK="$fake" FLEET_CGROUP_ROOT="$work/no-cgroup" FLEET_MEMINFO="$work/meminfo_low" \
  bash "$runner" "$work/fleet/test_fleet.sh")
check "suite skipped when MemAvailable is under 4500 MiB" \
  "$(grep -c '^skip .*test_fleet.sh: available memory is 1953 MiB' <<<"$out")" "1"

# 4. Heavy suite file runs when FLEET_SHELLCHECK_ALL=1 even under constraint
out=$(SHELLCHECK="$fake" FLEET_CGROUP_ROOT="$work/cgroup" FLEET_MEMINFO="$work/meminfo_low" FLEET_SHELLCHECK_ALL=1 \
  bash "$runner" "$work/fleet/test_fleet.sh")
check "suite runs when FLEET_SHELLCHECK_ALL=1" \
  "$out" "fake-shellcheck checked: -x $work/fleet/test_fleet.sh"

# 5. Heavy suite file runs when CI=true even under constraint
out=$(SHELLCHECK="$fake" FLEET_CGROUP_ROOT="$work/cgroup" FLEET_MEMINFO="$work/meminfo_low" CI=true \
  bash "$runner" "$work/fleet/test_fleet.sh")
check "suite runs when CI=true" \
  "$out" "fake-shellcheck checked: -x $work/fleet/test_fleet.sh"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
