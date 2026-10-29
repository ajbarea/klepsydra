#!/usr/bin/env bash
# install.sh [--dry-run]: install the fleet from this checkout. Each script is
# linked into the state folder (so a pull updates the fleet), the `fleet`
# command into ~/.local/bin, and the fleet's services into
# ~/.config/systemd/user as enabled user units, which come back after a
# restart. A copy a link replaces is kept in archive/fleet-scripts-<date>/.
# Starts nothing: `fleet cutover` swaps the running services onto the units.
set -u
FLEET_TARGET=fleet::install
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
dry=0 force=0
for a in "$@"; do
  case $a in --dry-run) dry=1 ;; --force) force=1 ;; esac
done
if (( !force )) && [[ $(git -C "$here" rev-parse --path-format=absolute --git-dir 2>/dev/null) != "$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ]]; then
  err "this checkout is a git worktree; links into it break when it is removed. Install from the main checkout, or pass --force."
  exit 2
fi
do_() { if (( dry )); then printf 'would: %s\n' "$*"; else "$@"; fi; }
SCRIPTS=(launch.sh fresh-now.sh resume-at-reset.sh watch-panes.sh memfrag-log.sh relaunch-fresh.sh brief.sh doctor.sh cutover.sh accounts-sync.sh recover.sh sync-briefing.sh ci_watch.py worker-settings.json)
UNITS=${FLEET_UNITS:-$HOME/.config/systemd/user}
BIN=${FLEET_BIN:-$HOME/.local/bin}
archive=$FLEET_STATE/archive/fleet-scripts-$(date +%Y%m%d)

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
do_ ln -sfn -- "$here/fleet" "$BIN/fleet"

# The PATH the services run with: this shell's, as `systemd-run -E PATH` gave them.
unit() { # NAME BODY
  if (( dry )); then printf 'would write %s/%s\n' "$UNITS" "$1"; else printf '%s\n' "$2" >"$UNITS/$1"; fi
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
# Enabling and starting is the cut-over's: a transient unit of the same name
# (systemd-run) makes enable fail until it is stopped (fleet cutover).
if (( ! dry )) && command -v "${FLEET_SYSTEMCTL:-systemctl}" >/dev/null; then
  "${FLEET_SYSTEMCTL:-systemctl}" --user daemon-reload
fi
(( dry )) || flog INFO "fleet installed" from="$here" state="$FLEET_STATE" archive="$archive"
echo "installed from $here; run fleet cutover to start the services on it"
