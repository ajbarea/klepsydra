.PHONY: install-hooks install-fleet test-fleet shellcheck

# Copy the hooks, status line, launcher and cast into ~/.claude (fleet/install.sh --hooks).
install-hooks:
	bash fleet/install.sh --hooks

# Those copies, then link the fleet scripts and user units into place (fleet/install.sh).
install-fleet:
	bash fleet/install.sh

# The heavy lock (#289): the suite starts tmux servers, and shellcheck over the tree
# took 1.7 GB on 11-03, when a worker's scope filled its task cap with both running.
HEAVY = flock -o /tmp/fleet-heavy.lock timeout 3600

test-fleet:
	$(HEAVY) bash fleet/test_fleet.sh

shellcheck:
	$(HEAVY) uvx --from shellcheck-py shellcheck fleet/*.sh fleet/fleet hooks/*.sh
