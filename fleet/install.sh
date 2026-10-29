#!/usr/bin/env bash
# install.sh [--dry-run]: install the fleet from this checkout. Each script is
# linked into the state folder (so a pull updates the fleet), the `fleet`
# command into ~/.local/bin, and the fleet's services into
# ~/.config/systemd/user as enabled user units, which come back after a
# restart. A copy a link replaces is kept in archive/fleet-scripts-<date>/.
# Starts nothing: `fleet cutover` restarts the resume service.
set -u
FLEET_TARGET=fleet::install
here=$(dirname "$(readlink -f "$0")")
# shellcheck source=fleet/lib.sh
. "$here/lib.sh"
dry=0
[[ ${1:-} == --dry-run ]] && dry=1
do_() { if (( dry )); then printf 'would: %s\n' "$*"; else "$@"; fi; }
SCRIPTS=(launch.sh fresh-now.sh resume-at-reset.sh watch-panes.sh memfrag-log.sh relaunch-fresh.sh brief.sh doctor.sh worker-settings.json)
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
if (( ! dry )) && command -v systemctl >/dev/null; then
  systemctl --user daemon-reload
  systemctl --user enable fleet-resume-at-reset.service fleet-memfrag-log.timer >/dev/null 2>&1
  [[ -r $mem_watch ]] && systemctl --user enable wsl-mem-watch.service >/dev/null 2>&1
fi
(( dry )) || flog INFO "fleet installed" from="$here" state="$FLEET_STATE" archive="$archive"
echo "installed from $here"
