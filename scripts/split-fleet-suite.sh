#!/usr/bin/env bash
# Split fleet/test_fleet.sh into the shards CI runs in parallel (#547).
# fleet/test_fleet.sh stays the source; the shards in fleet/tests/ are never committed.
#   bash scripts/split-fleet-suite.sh            write fleet/tests/prelude.sh and <area>.sh
#   git diff --name-only main... | bash scripts/split-fleet-suite.sh --select
#                                                 print the shards (JSON) a change reaches
#   bash scripts/split-fleet-suite.sh --list     print every shard (JSON)
set -euo pipefail
exec python3 -I "$(dirname "$0")/split_fleet_suite.py" "$@"
