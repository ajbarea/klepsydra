#!/usr/bin/env bash
# sandbox.sh OUT SCRIPT [ARGS...]: run one fleet script (fleet/SCRIPT) from
# this checkout against the LIVE tmux panes, but with copies of the fleet
# state and the klepsydra data folder under OUT (made on first use, `rm -rf
# OUT` to refresh), a read-only tmux, no launches, no systemctl and no
# recover. What it would have written lands in the copies; what it tried to
# type is in OUT/shim.log. For measuring a pass on real panes and real data.
set -u
out=$1 script=$2
shift 2
here=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
repo=${here%/scripts/perf/forks}
live_state=${LIVE_FLEET_STATE:-$HOME/.local/state/fleet-orchestrator}
live_k=${LIVE_KLEPSYDRA_DIR:-/mnt/c/Users/$USER/AppData/Local/dev.ajsoftworks.klepsydra}
mkdir -p "$out"
# SANDBOX_SEED: a folder made by an earlier sandbox run; its untouched copies
# (seed/state, seed/kdir) seed this one, so two checkouts see the same data.
if [[ -n ${SANDBOX_SEED:-} && ! -d $out/state ]]; then
  cp -a "$SANDBOX_SEED/state" "$SANDBOX_SEED/kdir" "$out/"
fi
if [[ ! -d $out/state ]]; then
  rsync -a --exclude ci --exclude headless --exclude 'inbox-2026-*' --exclude delegate --exclude handoff \
    --exclude archive --exclude log --exclude research "$live_state/" "$out/state/"
  mkdir -p "$out/state/log"
fi
[[ -d $out/kdir ]] || rsync -a --exclude EBWebView --exclude agora "$live_k/" "$out/kdir/"
mkdir -p "$out/shim"
ln -sf "$here/tmux-ro" "$out/shim/tmux"
export PATH=$out/shim:$PATH FLEET_STATE=$out/state KLEPSYDRA_DIR=$out/kdir SHIM_LOG=$out/shim.log \
  LAUNCH=/bin/false DOCTOR=/bin/true FLEET_SYSTEMCTL=/nonexistent FLEET_RECOVER=/bin/false FRESH_AFTER_S=99999999
exec bash "$repo/fleet/$script" "$@"
