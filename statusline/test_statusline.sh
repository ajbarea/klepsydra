#!/usr/bin/env bash
# Fixture-driven tests for the statusLine producer. Run: bash statusline/test_statusline.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/klepsydra-statusline.sh"
fixtures="$here/fixtures"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

pass=0 fail=0

check() {
  local name=$1 got=$2 want=$3
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1)); printf '  ok   %s\n' "$name"
  else
    fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$name" "$want" "$got"
  fi
}

# A config dir per account, mirroring what CLAUDE_CONFIG_DIR gives each login.
mkconfig() { # dir, accountUuid, organizationType, organizationName
  mkdir -p "$work/$1"
  cat >"$work/$1/.claude.json" <<EOF
{"oauthAccount":{"accountUuid":"$2","organizationType":"$3","organizationName":"$4",
                 "emailAddress":"someone@example.edu"}}
EOF
}
mkconfig team     "uuid-team" "claude_team" "RIT-CS-DQL"
mkconfig personal "uuid-pers" "claude_pro"  "Personal Org"
mkdir -p "$work/empty"   # config dir with no .claude.json at all

run() { # fixture, config-dir
  CLAUDE_CONFIG_DIR="$work/$2" KLEPSYDRA_DIR="$work/out" bash "$script" <"$fixtures/$1"
}
# account dir / session file, mirroring the layout the overlay reads.
acct() { echo "$work/out/accounts/$1/${2:-abc-123}.json"; }

echo "statusLine producer"

# --- both windows present -------------------------------------------------
rm -rf "$work/out"
display=$(run full.json team)
check "full: terminal line" "$display" "Opus 5 · ctx 21% · 5h 73% · 7d 12%"
check "full: five_hour pct"   "$(jq -r '.windows.five_hour.used_percentage' "$(acct uuid-team)")" "73.2"
check "full: five_hour reset" "$(jq -r '.windows.five_hour.resets_at' "$(acct uuid-team)")" "1789000000"
check "full: seven_day pct"   "$(jq -r '.windows.seven_day.used_percentage' "$(acct uuid-team)")" "12.9"
check "full: written_at set"  "$(jq -r '.written_at | if . > 1700000000 then "yes" else "no" end' "$(acct uuid-team)")" "yes"

# --- account identity ------------------------------------------------------
check "team: label from org name" "$(jq -r '.label' "$(acct uuid-team)")" "RIT-CS-DQL"
check "team: account id"          "$(jq -r '.account' "$(acct uuid-team)")" "uuid-team"

rm -rf "$work/out"
run five-hour-only.json personal >/dev/null
check "personal: label"    "$(jq -r '.label' "$(acct uuid-pers abc-124)")" "Personal"
check "personal: account"  "$(jq -r '.account' "$(acct uuid-pers abc-124)")" "uuid-pers"

# --- two accounts must not overwrite each other ---------------------------
rm -rf "$work/out"
run full.json team >/dev/null
run five-hour-only.json personal >/dev/null
check "two accounts: both dirs exist" \
  "$(cd "$work/out/accounts" && printf '%s ' */)" "uuid-pers/ uuid-team/ "
check "two accounts: team intact" "$(jq -r '.windows.five_hour.used_percentage' "$(acct uuid-team)")" "73.2"
check "two accounts: personal intact" "$(jq -r '.windows.five_hour.used_percentage' "$(acct uuid-pers abc-124)")" "1"

# --- two sessions of ONE account each keep their own file ------------------
# Sharing a file let an idle terminal overwrite an active one with a stale
# number, which showed up as the reading flipping between values.
rm -rf "$work/out"
run full.json team >/dev/null            # session abc-123, 73.2%
run five-hour-only.json team >/dev/null  # session abc-124, 1%
check "two sessions: both files kept" \
  "$(cd "$work/out/accounts/uuid-team" && printf '%s ' *.json)" "abc-123.json abc-124.json "
check "two sessions: first intact"  "$(jq -r '.windows.five_hour.used_percentage' "$(acct uuid-team abc-123)")" "73.2"
check "two sessions: second intact" "$(jq -r '.windows.five_hour.used_percentage' "$(acct uuid-team abc-124)")" "1"
check "session id recorded"         "$(jq -r '.session' "$(acct uuid-team abc-124)")" "abc-124"

# --- missing config falls back rather than failing ------------------------
rm -rf "$work/out"
display=$(run full.json empty)
check "no config: still echoes" "$display" "Opus 5 · ctx 21% · 5h 73% · 7d 12%"
check "no config: unknown id"   "$(jq -r '.account' "$(acct unknown)")" "unknown"
check "no config: label"        "$(jq -r '.label' "$(acct unknown)")" "Claude"

# --- 0% must publish, not vanish -----------------------------------------
rm -rf "$work/out"
display=$(run zero-pct.json team)
check "zero pct: terminal line" "$display" "Opus 5 · ctx 0% · 5h 0%"
check "zero pct: published"     "$(jq -r '.windows.five_hour.used_percentage' "$(acct uuid-team abc-127)")" "0"

# --- gateway spend limit --------------------------------------------------
rm -rf "$work/out"
display=$(run spend-limit.json team)
check "spend limit: terminal line" "$display" "Opus 5 · ctx 50% · spend 100%"
check "spend limit: published"     "$(jq -r '.windows.spend_limit.used_percentage' "$(acct uuid-team abc-126)")" "100"

# --- absent rate_limits must NOT clobber a good file ----------------------
rm -rf "$work/out"; mkdir -p "$work/out/accounts/uuid-team"
printf '{"account":"uuid-team","written_at":1,"windows":{"five_hour":{"used_percentage":99,"resets_at":2}}}\n' >"$(acct uuid-team)"
display=$(run no-rate-limits.json team)
check "no limits: terminal line"  "$display" "Opus 5"
check "no limits: file preserved" "$(jq -r '.windows.five_hour.used_percentage' "$(acct uuid-team)")" "99"

# --- malformed stdin must not clobber, must not error ---------------------
display=$(run malformed.json team); rc=$?
check "malformed: exit 0"         "$rc" "0"
check "malformed: silent"         "$display" ""
check "malformed: file preserved" "$(jq -r '.windows.five_hour.used_percentage' "$(acct uuid-team)")" "99"

# --- no stray temp files left behind --------------------------------------
check "no tmp litter" "$(find "$work/out" -name '*.tmp' | wc -l)" "0"

# --- unwritable destination must not kill the status line -----------------
display=$(CLAUDE_CONFIG_DIR="$work/team" KLEPSYDRA_DIR="/proc/nonexistent" bash "$script" <"$fixtures/full.json"); rc=$?
check "unwritable dest: exit 0"       "$rc" "0"
check "unwritable dest: still echoes" "$display" "Opus 5 · ctx 21% · 5h 73% · 7d 12%"

# --- default destination must track the overlay's bundle identifier -------
# Producer and consumer agree on the path by convention alone, so a rename of
# one side is otherwise silent: the gauge simply never sees a reading.
identifier=$(jq -r '.identifier' "$here/../src-tauri/tauri.conf.json")
# shellcheck disable=SC2016  # sed pattern: the default must stay unexpanded.
default=$(sed -n 's/^: "${KLEPSYDRA_DIR:=\(.*\)}"$/\1/p' "$script")
# Both halves read out of a file, so both can come back empty -- and two empty
# strings compare equal, which would pass this test by reading nothing at all.
check "identifier is readable"  "$([[ -n "$identifier" ]] && echo yes)" "yes"
check "hook default is readable" "$([[ -n "$default" ]] && echo yes)"   "yes"
# The whole path, not just its last component: Roaming instead of Local, or the
# install dir with the identifier appended, both end in the right name.
# $USER is compared unexpanded: the hook resolves it at run time, per user.
# shellcheck disable=SC2016  # that is the point: the literal, not this user's.
check "default dir is the app data dir" "$default" \
  '/mnt/c/Users/$USER/AppData/Local/'"$identifier"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
