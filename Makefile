.PHONY: install-hooks install-fleet test-fleet test-launch test-delegate test-engine test-headless test-heavy-lock test-slice test-forks shellcheck test-shellcheck

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
# The files and flags CI's shell lint uses. The runner checks a file too big for
# the room left without dataflow analysis, rather than be killed (#503).
SHELLCHECK ?= bash scripts/shellcheck.sh
SHELL_FILES = hooks/*.sh statusline/*.sh scripts/*.sh fleet/*.sh fleet/fleet

# SHARD=<area> runs one shard of it, as CI runs a pull request (#547); the shards a
# change reaches: git diff --name-only main... | bash scripts/split-fleet-suite.sh --select
test-fleet:
	$(HEAVY) bash $(if $(SHARD),-c 'bash scripts/split-fleet-suite.sh && exec bash fleet/tests/$(SHARD).sh',fleet/test_fleet.sh)

test-launch:
	$(HEAVY) bash hooks/test_launch.sh

test-delegate:
	$(HEAVY) bash fleet/test_delegate.sh

test-engine:
	bash hooks/test_engine.sh

# fleet headless (#260): starts no tmux server, so it runs without the lock.
test-headless:
	bash fleet/test_headless.sh

test-heavy-lock:
	$(HEAVY) bash fleet/test_heavy_lock.sh

# Fork budgets (#492): each fleet/test_forks_*.sh counts the processes a hot
# path starts (strace) and checks a rewrite against the code it replaced.
# No tmux server: runs without the lock.
test-forks:
	@for t in fleet/test_forks_*.sh; do echo "== $$t"; bash "$$t" || exit 1; done

# The memory slices and OOM ranks (#353); its live part needs a user manager and
# skips without one (CI), and reads WSL's free memory, so it takes the lock.
test-slice:
	$(HEAVY) bash fleet/test_slice.sh

shellcheck:
	$(HEAVY) $(SHELLCHECK) -x $(SHELL_FILES)

# The runner's own tests: stubs only, no tmux, so no lock.
test-shellcheck:
	bash scripts/test_shellcheck.sh
