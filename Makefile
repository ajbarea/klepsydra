.PHONY: install-hooks install-fleet test-fleet test-launch test-delegate test-heavy-lock shellcheck

# Copy the hooks, status line, launcher and cast into ~/.claude (fleet/install.sh --hooks).
install-hooks:
	bash fleet/install.sh --hooks

# Those copies, then link the fleet scripts and user units into place (fleet/install.sh).
install-fleet:
	bash fleet/install.sh

# The heavy lock (#289): the suite starts tmux servers, and shellcheck over the tree
# took 1.7 GB on 11-03, when a worker's scope filled its task cap with both running.
# These targets take it themselves, so run them bare: inside another flock on the
# same file the inner one would wait on the outer forever. FLEET_HEAVY_HELD=1 says
# the caller holds it already (or, in CI, that there is none to take); any other
# value takes it. fleet/heavy.sh says when it waits, refuses a lock its caller
# holds, and ends every process the run started at its limit or on Ctrl-C.
HEAVY = $(if $(filter 1,$(FLEET_HEAVY_HELD)),,FLEET_HEAVY_HELD=1 bash fleet/heavy.sh)
# The files and flags CI's shell lint uses.
SHELLCHECK ?= uvx --from shellcheck-py shellcheck
SHELL_FILES = hooks/*.sh statusline/*.sh scripts/*.sh fleet/*.sh fleet/fleet

test-fleet:
	$(HEAVY) bash fleet/test_fleet.sh

test-launch:
	$(HEAVY) bash hooks/test_launch.sh

test-delegate:
	$(HEAVY) bash fleet/test_delegate.sh

test-heavy-lock:
	$(HEAVY) bash fleet/test_heavy_lock.sh

shellcheck:
	$(HEAVY) $(SHELLCHECK) -x $(SHELL_FILES)
