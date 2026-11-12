#!/usr/bin/env bash
# install.sh [--dry-run] [--hooks] [--no-cutover]: install the fleet from this checkout (with
# --hooks, only the copies in ~/.claude, which the gauge alone needs). Each script is
# linked into the state folder (so a pull updates the fleet), the `fleet`
# command into ~/.local/bin, the hooks, status line, launcher and cast copied
# into ~/.claude (FLEET_HOOK_DIR), and the fleet's services into
# ~/.config/systemd/user as enabled user units, which come back after a
# restart. A copy a link replaces is kept in archive/fleet-scripts-<date>/.
# When the resume service is running, ends with `fleet cutover`, so the
# services run the new scripts (--no-cutover leaves that to you).
set -u
FLEET_TARGET=fleet::install
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
dry=0 force=0 hooks_only=0 cut=1
for a in "$@"; do
  case $a in --dry-run) dry=1 ;; --force) force=1 ;; --hooks) hooks_only=1 ;; --no-cutover) cut=0 ;; esac
done
if (( !force )) && [[ $(git -C "$here" rev-parse --path-format=absolute --git-dir 2>/dev/null) != "$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ]]; then
  err "this checkout is a git worktree; links into it break when it is removed. Install from the main checkout, or pass --force."
  exit 2
fi
do_() { if (( dry )); then printf 'would: %s\n' "$*"; else "$@"; fi; }
# A dry run writes nothing, its log included: its events go to stderr only.
ilog() { if (( dry )); then printf '%s %s %s\n' "$(date '+%F %T')" "$1" "${*:2}" >&2; else flog "$@"; fi; }
SCRIPTS=(launch.sh delegate.sh engines.sh fresh-now.sh resume-at-reset.sh watch-panes.sh tmux-watch.sh memfrag-log.sh relaunch-fresh.sh done.sh send.sh voices.sh brief.sh doctor.sh cutover.sh accounts-sync.sh recover.sh pause.sh registry-event.sh sync-briefing.sh ci_watch.py worker-settings.json)
# Scripts the checkout no longer has: their links in the state folder go (#326).
RETIRED=(agora.py)
UNITS=$FLEET_UNIT_DIR
BIN=${FLEET_BIN:-$HOME/.local/bin}
archive=$FLEET_STATE/archive/fleet-scripts-$(date +%Y%m%d)

# The hooks, status line, launcher and cast are copies, not links: each is
# swapped in by a rename in its own folder, only once written whole, so a
# session never reads one half written (#244). A copy that differs is archived
# first, under the time and this run's pid, so a later install keeps the first.
root=${here%/fleet} failed=0 stamp=$(date +%H%M%S).$$
for c in "${HOOK_COPIES[@]}"; do
  src=$root/${c%% *} name=${c#* }
  dest=$FLEET_HOOK_DIR/$name tmp=$FLEET_HOOK_DIR/$name.new.$$
  if [[ ! -f $src ]]; then
    ilog ERROR "a copy's source is missing from this checkout; not installed" file="$dest" from="$src"; failed=1; continue
  fi
  if [[ -e $dest && ! -f $dest ]]; then
    ilog ERROR "a copy's place is not a file; left alone" file="$dest"; failed=1; continue
  fi
  cmp -s -- "$src" "$dest" && continue
  mode=644; [[ $src == *.sh ]] && mode=755
  if (( dry )); then
    printf 'would: install %s to %s\n' "$src" "$dest"; continue
  fi
  if mkdir -p -- "${dest%/*}" &&
     { [[ ! -e $dest ]] || { mkdir -p -- "$archive/claude" && cp -p -- "$dest" "$archive/claude/${name//\//_}.$stamp"; }; } &&
     install -m "$mode" -- "$src" "$tmp" && mv -f -- "$tmp" "$dest"; then
    ilog INFO "installed a copy" file="$dest" from="$src"
  else
    rm -f -- "${FLEET_HOOK_DIR:?}/${name:?}.new.$$"
    ilog ERROR "a copy was not installed; the old one stays" file="$dest" from="$src"
    failed=1
  fi
done
# A running fleet server read its conf when it started, so it never sees a new
# hook: tmux-conf.sh has it read the installed conf now (#290). Off in the
# suite, which tests the script itself (FLEET_LIVE_CONF=0).
if (( !dry )) && [[ ${FLEET_LIVE_CONF:-1} == 1 ]]; then
  bash "$here/tmux-conf.sh" "$FLEET_HOOK_DIR" || failed=1
fi
if (( hooks_only )); then
  (( failed )) && exit 1
  (( dry )) || echo "hooks installed from $root into $FLEET_HOOK_DIR"
  exit 0
fi

do_ mkdir -p -- "$FLEET_STATE" "$UNITS" "$BIN"
for f in "${SCRIPTS[@]}"; do
  [[ -e $here/$f ]] || continue
  dest=$FLEET_STATE/$f
  if [[ -e $dest && ! -L $dest ]]; then
    do_ mkdir -p -- "$archive"
    do_ mv -- "$dest" "$archive/$f"
  fi
  do_ ln -sfn -- "$here/$f" "$dest"
done
# Only a link: a file there is someone's own, and stays.
for f in "${RETIRED[@]}"; do
  [[ -L $FLEET_STATE/$f ]] || continue
  do_ rm -f -- "${FLEET_STATE:?}/${f:?}"
  ilog INFO "a retired script's link removed" link="$FLEET_STATE/$f"
done
do_ ln -sfn -- "$here/fleet" "$BIN/fleet"


# The PATH the services run with: this shell's, as `systemd-run -E PATH` gave them.
# A unit already as written is left alone, and one that changed is rewritten in
# place, so its birth says when it was first written (doctor dates the slices
# by it, #353).
unit() { # NAME BODY
  if (( dry )); then printf 'would write %s/%s\n' "$UNITS" "$1"
  elif [[ ! -f $UNITS/$1 || "$(<"$UNITS/$1")" != "$2" ]]; then printf '%s\n' "$2" >"$UNITS/$1"; fi
}
unit fleet-resume-at-reset.service "[Unit]
Description=klepsydra fleet: resume panes stopped on a usage limit

[Service]
Environment=\"PATH=$PATH\" \"HOME=$HOME\"
ExecStart=/usr/bin/bash $FLEET_STATE/resume-at-reset.sh
Restart=always
RestartSec=30

[Install]
WantedBy=default.target"
unit fleet-memfrag-log.service "[Unit]
Description=klepsydra fleet: log WSL memory fragmentation

[Service]
Type=oneshot
ExecStart=/usr/bin/bash $FLEET_STATE/memfrag-log.sh"
unit fleet-memfrag-log.timer "[Unit]
Description=klepsydra fleet: log WSL memory fragmentation every 30 min

[Timer]
OnCalendar=*:0/30
Persistent=true

[Install]
WantedBy=timers.target"
# The second config folder follows ~/.claude: on every change to its settings
# or plugin lists (systemd.path PathChanged), and hourly for .claude.json's
# shared keys, which change too often to watch.
unit fleet-accounts-sync.service "[Unit]
Description=klepsydra fleet: keep the second Claude Code config folder like ~/.claude

[Service]
Type=oneshot
Environment=\"PATH=$PATH\" \"HOME=$HOME\"
ExecStart=/usr/bin/bash $FLEET_STATE/accounts-sync.sh"
unit fleet-accounts-sync.path "[Unit]
Description=klepsydra fleet: sync the second config folder when ~/.claude's settings change

[Path]
PathChanged=$HOME/.claude/settings.json
PathChanged=$HOME/.claude/plugins/installed_plugins.json
PathChanged=$HOME/.claude/plugins/known_marketplaces.json
Unit=fleet-accounts-sync.service

[Install]
WantedBy=default.target"
unit fleet-accounts-sync.timer "[Unit]
Description=klepsydra fleet: sync the second config folder hourly

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target"
# AJ's briefing repo, committed and pushed when it changed.
unit fleet-sync-briefing.service "[Unit]
Description=klepsydra fleet: commit and push the fleet-briefing repo

[Service]
Type=oneshot
TimeoutStartSec=180
Environment=\"PATH=$PATH\" \"HOME=$HOME\"
ExecStart=/usr/bin/bash $FLEET_STATE/sync-briefing.sh"
unit fleet-sync-briefing.timer "[Unit]
Description=klepsydra fleet: sync the fleet-briefing repo every 5 min

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target"
# Fleet health on the wall (#208): doctor every 5 min into the data folder. Exit 1 is
# a failing check, which the wall shows, not a failed run.
unit fleet-doctor.service "[Unit]
Description=klepsydra fleet: fleet doctor for the wall's Fleet health

[Service]
Type=oneshot
TimeoutStartSec=120
SuccessExitStatus=1
# What it prints is in the report; the journal would keep a Remote Control link each run.
StandardOutput=null
Environment=\"PATH=$PATH\" \"HOME=$HOME\"${WSL_DISTRO_NAME:+ \"WSL_DISTRO_NAME=$WSL_DISTRO_NAME\"}
ExecStart=/usr/bin/bash $FLEET_STATE/doctor.sh --json \"$KLEPSYDRA_DIR/fleet-health.json\""
unit fleet-doctor.timer "[Unit]
Description=klepsydra fleet: fleet doctor every 5 min

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target"
# The tmux server watchdog (#290): fleet recover once a crash ends the server.
unit fleet-tmux-watch.service "[Unit]
Description=klepsydra fleet: fleet recover when the fleet's tmux server crashes

[Service]
Type=oneshot
# A recover staggers its launches a minute apart, so a fleet takes a while.
TimeoutStartSec=3600
Environment=\"PATH=$PATH\" \"HOME=$HOME\"${WSL_DISTRO_NAME:+ \"WSL_DISTRO_NAME=$WSL_DISTRO_NAME\"}
ExecStart=/usr/bin/bash $FLEET_STATE/tmux-watch.sh"
unit fleet-tmux-watch.timer "[Unit]
Description=klepsydra fleet: check the fleet's tmux server every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=1s

[Install]
WantedBy=timers.target"
# The CI watch (#162), with the ci-audit report script from techne's main checkout.
unit fleet-ci-watch.service "[Unit]
Description=klepsydra fleet: watch the sisters' CI for red runs

[Service]
Environment=\"PATH=$PATH\" \"HOME=$HOME\" \"TECHNE_CI_REPORT=${TECHNE_CI_REPORT:-$HOME/ajsoftworks/techne/plugins/techne/skills/ci-audit/scripts/report.sh}\" \"CI_SWEEP_HOUR=${CI_SWEEP_HOUR:-99}\"
ExecStart=/usr/bin/python3 -I $FLEET_STATE/ci_watch.py
Restart=always
RestartSec=60

[Install]
WantedBy=default.target"
mem_watch=$HOME/.local/state/wsl-mem-watch/watch.sh
if [[ -r $mem_watch ]]; then
  unit wsl-mem-watch.service "[Unit]
Description=WSL memory watch

[Service]
Environment=\"PATH=$PATH\" \"HOME=$HOME\"
ExecStart=/usr/bin/bash $mem_watch
Restart=always
RestartSec=30

[Install]
WantedBy=default.target"
fi
# The fleet's memory slices (#353), sized from this machine now; the reload below
# hands new caps to a slice already running. A scope finds its slice by name, so
# neither is enabled.
if caps=$(fleet_slice_caps); then
  read -r all workers margin <<<"$caps"
  unit "$FLEET_SLICE" "$(fleet_slice_unit "klepsydra fleet: every fleet scope's memory together, the orchestrator's included" "$all")"
  unit "$FLEET_WORKER_SLICE" "$(fleet_slice_unit "klepsydra fleet: the workers' memory, leaving the orchestrator its peak" "$workers")"
  ilog INFO "memory slices sized" fleet_mb="$all" workers_mb="$workers" orchestrator_mb="$((all - workers))" margin_mb="$margin"
else
  ilog ERROR "memory slices not sized: no MemTotal in /proc/meminfo, no orchestrator reading and no MEM_MAX size, or the orchestrator's peak leaves the workers nothing or all" mem_max="${MEM_MAX:-5G}"
  failed=1
fi
# Enabling and starting is the cut-over's: a transient unit of the same name
# (systemd-run) makes enable fail until it is stopped (fleet cutover).
if (( ! dry )) && command -v "${FLEET_SYSTEMCTL:-systemctl}" >/dev/null; then
  "${FLEET_SYSTEMCTL:-systemctl}" --user daemon-reload
fi
(( dry )) || flog INFO "fleet installed" from="$here" state="$FLEET_STATE" archive="$archive"
(( failed )) && exit 1
(( dry )) && exit 0
# A running service keeps the code it read at its start (#263): an install
# onto a live fleet cuts over at once, so the new scripts are the ones running.
sc=${FLEET_SYSTEMCTL:-systemctl}
if (( cut )) && command -v "$sc" >/dev/null && "$sc" --user is-active --quiet fleet-resume-at-reset.service 2>/dev/null; then
  flog INFO "install cuts the running fleet over to the new scripts" from="$here"
  if bash "$here/cutover.sh"; then
    echo "installed from $here and cut over: the services run the new scripts"
  else
    flog ERROR "install: the cut-over failed; the services may still run the old scripts" from="$here"
    err "installed, but the cut-over failed: run fleet cutover and read its log"
    exit 1
  fi
else
  echo "installed from $here; run fleet cutover to start the services on it"
fi
exit 0
