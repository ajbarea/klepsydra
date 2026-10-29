.PHONY: install-fleet test-fleet

# Link the fleet scripts and user units into place (fleet/install.sh).
install-fleet:
	bash fleet/install.sh

test-fleet:
	bash fleet/test_fleet.sh
