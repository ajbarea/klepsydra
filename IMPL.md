# IMPL: close the Playwright MCP browser when done (#379), branch headless-browser-379

Resume from this file, `git log`, the PR and the comments on #379.

## Slice
One script, `hooks/klepsydra-browser.sh` (installed to ~/.claude as a hook copy), matches only a Chrome main process (no `--type=`) whose exact `--user-data-dir=` is `.../ms-playwright-mcp/mcp-chrome-*` (or the older `.../ms-playwright/mcp-chrome-*`); it finds the MCP server and claude as its ancestors. Modes: SessionEnd hook (TERM this session's browsers, KILL after 1 s), `--reap STATE` (orphans: no server ancestor and reparented to init/systemd; TERM, KILL at a later call past the grace), `--list` (pid, server, claude, idle from the profile's newest mtime). Wired into: the resume pass (`reap_browsers`, FLEET_BROWSERS=0 in the suite), `fleet doctor` ("MCP browsers", FLEET_BROWSER_IDLE_MIN), brief-tail.md and headless-rules.md rule, README (hook block, doctor and resume rows), CI step.

## Done
- Code, `hooks/test_browser.sh` (33 checks, 7 mutations), 8 cases in fleet/test_fleet.sh (doctor, resume pass, rule text), shellcheck clean, test-headless 116/116.
- test_fleet from the top through the doctor section: 309/309 (before the rule-text check was added).

## Next
1. Run test-fleet in full (the install section onward checks HOOK_COPIES, now one longer), test-launch.
2. Independent review; register the SessionEnd hook in ~/.claude/settings.json after merge (`make install-hooks`, then the README block).
