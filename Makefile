.PHONY: install-hooks install-fleet test-fleet

# Copy the hooks, status line, launcher and cast into ~/.claude (fleet/install.sh --hooks).
install-hooks:
	bash fleet/install.sh --hooks

# Those copies, then link the fleet scripts and user units into place (fleet/install.sh).
install-fleet:
	bash fleet/install.sh

test-fleet:
	bash fleet/test_fleet.sh
