#!/usr/bin/env bash
# Fixture-driven tests for the statusLine producer. Run: bash statusline/test_statusline.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
script="$here/klepsydra-statusline.sh"
fixtures="$here/fixtures"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# A fixed clock before the fixtures' resets, so their windows are live, and a
# runtime dir of the suite's own for the hourly prune stamp.
export KLEPSYDRA_NOW=1788990000
export XDG_RUNTIME_DIR="$work/run"
mkdir -p "$XDG_RUNTIME_DIR"

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

# --- a re-render is not a new reading --------------------------------------
# Claude Code re-runs the hook on refreshInterval, at a window's reset time and
# on mode toggles, each time with the session's last API response. Publishing
# those stamped every idle terminal with a fresh time and with whichever login
# was current, so an old reading outlived a mid-window reset and landed under
# the account signed in after it.
run_json() { # json, config-dir
  CLAUDE_CONFIG_DIR="$work/$2" KLEPSYDRA_DIR="$work/out" bash "$script" <<<"$1"
}
full=$(cat "$fixtures/full.json")
stamp() { jq -r '.written_at' "$1"; }
backdate() { jq -c '.written_at = 1' "$1" >"$1.new" && mv "$1.new" "$1"; }

rm -rf "$work/out"
run full.json team >/dev/null
backdate "$(acct uuid-team)"
display=$(run full.json team)
check "re-render: still echoes"      "$display" "Opus 5 · ctx 21% · 5h 73% · 7d 12%"
check "re-render: publishes nothing" "$(stamp "$(acct uuid-team)")" "1"

# The window Claude Code drops at its reset time is still the same response.
run_json "$(jq -c 'del(.rate_limits.five_hour)' <<<"$full")" team >/dev/null
check "dropped window: publishes nothing" "$(stamp "$(acct uuid-team)")" "1"
check "dropped window: keeps both windows" \
  "$(jq -r '.windows | keys | join(",")' "$(acct uuid-team)")" "five_hour,seven_day"

# Signing into another account must not carry this session's reading over.
run full.json personal >/dev/null
check "login switch: nothing under the new account" \
  "$([[ -e "$(acct uuid-pers)" ]] && echo leaked || echo clean)" "clean"
check "login switch: original account intact" "$(stamp "$(acct uuid-team)")" "1"

# The next real response comes from the new login, and belongs to it.
newer=$(jq -c '.rate_limits.five_hour.used_percentage = 4 | .rate_limits.five_hour.resets_at = 1789009000' <<<"$full")
run_json "$newer" personal >/dev/null
check "new response: published under the new account" \
  "$(jq -r '.windows.five_hour.used_percentage' "$(acct uuid-pers)")" "4"
check "new response: old account untouched" "$(stamp "$(acct uuid-team)")" "1"

# A change in any window is a new reading, a drop within one included.
rm -rf "$work/out"
run full.json team >/dev/null
backdate "$(acct uuid-team)"
run_json "$(jq -c '.rate_limits.seven_day.used_percentage = 3' <<<"$full")" team >/dev/null
check "mid-window drop: republished" "$(jq -r '.windows.seven_day.used_percentage' "$(acct uuid-team)")" "3"
check "mid-window drop: restamped" \
  "$(jq -r '.written_at | if . > 1700000000 then "yes" else "no" end' "$(acct uuid-team)")" "yes"

# Claude Code's API time only grows on a response, so it tells a new response
# that repeats the numbers apart from a re-render, and the file is restamped.
timed() { jq -c --argjson ms "$1" '.cost.total_api_duration_ms = $ms' <<<"$full"; }
rm -rf "$work/out"
run_json "$(timed 5000)" team >/dev/null
check "observed_at recorded" "$(jq -r '.observed_at == .written_at' "$(acct uuid-team)")" "true"
check "api time recorded"    "$(jq -r '.api_ms' "$(acct uuid-team)")" "5000"
backdate "$(acct uuid-team)"
run_json "$(timed 5000)" team >/dev/null
check "same api time: publishes nothing" "$(stamp "$(acct uuid-team)")" "1"
run_json "$(timed 7400)" team >/dev/null
check "new response, same numbers: restamped" \
  "$(jq -r '.written_at | if . > 1700000000 then "yes" else "no" end' "$(acct uuid-team)")" "yes"
check "new response, same numbers: api time moves" "$(jq -r '.api_ms' "$(acct uuid-team)")" "7400"

# API time can restart lower under the same session id; any change is a response.
backdate "$(acct uuid-team)"
run_json "$(timed 300)" team >/dev/null
check "api time went down: restamped" \
  "$(jq -r '.written_at | if . > 1700000000 then "yes" else "no" end' "$(acct uuid-team)")" "yes"

# A config that parses but holds an odd oauthAccount still publishes.
mkdir -p "$work/odd" && printf '{"oauthAccount":"signed-out"}' >"$work/odd/.claude.json"
rm -rf "$work/out"
run full.json odd >/dev/null
check "odd oauthAccount: published as unknown" "$(jq -r '.account' "$(acct unknown)")" "unknown"

# A config caught mid-write must not file the reading under "unknown".
mkdir -p "$work/torn" && printf '{"oauthAccount":{"accountUu' >"$work/torn/.claude.json"
rm -rf "$work/out"
display=$(run full.json torn)
check "torn config: still echoes"     "$display" "Opus 5 · ctx 21% · 5h 73% · 7d 12%"
check "torn config: publishes nothing" "$([[ -e "$work/out/accounts" ]] && echo leaked || echo clean)" "clean"

# One that cannot be read at all is not mid-write; publish as before.
if [[ $EUID -ne 0 ]]; then
  mkdir -p "$work/locked" && printf '{}' >"$work/locked/.claude.json" && chmod 000 "$work/locked/.claude.json"
  rm -rf "$work/out"
  run full.json locked >/dev/null
  check "unreadable config: published as unknown" "$(jq -r '.label' "$(acct unknown)")" "Claude"
  chmod 600 "$work/locked/.claude.json"
fi

# An unreadable earlier file must not stop a good reading publishing.
rm -rf "$work/out"; mkdir -p "$work/out/accounts/uuid-team"
printf 'not json' >"$(acct uuid-team)"
run full.json team >/dev/null
check "corrupt previous: replaced" "$(jq -r '.windows.five_hour.used_percentage' "$(acct uuid-team)")" "73.2"

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

# --- the fleet heartbeat ----------------------------------------------------
# One line per session: its name (the terminal tab title) and the 10 s bucket
# it was written in. A render in the same bucket with the same name writes
# nothing; refreshInterval re-renders every 30 s, so a live session beats.
B=cb9fa591-1514-44d1-a31c-eba4a7cb41ed
beat="$work/out/fleet/$B.beat"
named=$(cat "$fixtures/named-session.json")
beat_run() { # epoch-seconds [json]
  CLAUDE_CONFIG_DIR="$work/team" KLEPSYDRA_DIR="$work/out" KLEPSYDRA_NOW="$1" bash "$script" <<<"${2:-$named}"
}
tab=$'\t'
rm -rf "$work/out"
display=$(beat_run 1792353001)
check "beat: still echoes"        "$display" "Opus 5 · ctx 21% · 5h 73% · 7d 12%"
check "beat: name and bucket"     "$(cat "$beat")" "Plan the fleet visualizer${tab}179235300"
touch -d @1 "$beat"
beat_run 1792353009 >/dev/null
check "beat: same bucket, no write" "$(stat -c %Y "$beat")" "1"
beat_run 1792353010 >/dev/null
check "beat: next bucket, rewritten" "$(cat "$beat")" "Plan the fleet visualizer${tab}179235301"
touch -d @1 "$beat"
beat_run 1792353011 "$(jq -c '.session_name = "fleet-plan"' <<<"$named")" >/dev/null
check "beat: a rename writes at once" "$(cat "$beat")" "fleet-plan${tab}179235301"
beat_run 1792353020 "$(jq -c 'del(.session_name)' <<<"$named")" >/dev/null
check "beat: no name yet"          "$(cat "$beat")" "${tab}179235302"
beat_run 1792353030 "$(jq -c '.session_name = "a\tb\nc"' <<<"$named")" >/dev/null
check "beat: tabs and newlines flattened" "$(cat "$beat")" "a b c${tab}179235303"
rm -rf "$work/out"
beat_run 1792353040 "$(jq -c 'del(.rate_limits)' <<<"$named")" >/dev/null
check "beat: written without rate limits" "$([[ -f $beat ]] && echo yes)" "yes"
rm -rf "$work/out"
run full.json team >/dev/null
check "beat: none for a session id that is not a uuid" "$(find "$work/out" -name '*.beat' | wc -l)" "0"
check "beat: no tmp litter" "$(find "$work/out" -name '*.tmp' | wc -l)" "0"

# --- no HOME, no USER: still echoes, publishes nothing ----------------------
rm -rf "$work/out"
display=$(env -u HOME -u USER -u CLAUDE_CONFIG_DIR -u KLEPSYDRA_DIR -u XDG_DATA_HOME \
  bash "$script" <"$fixtures/named-session.json" 2>"$work/err"); rc=$?
check "no HOME/USER: exit 0"       "$rc" "0"
check "no HOME/USER: still echoes" "$display" "Opus 5 · ctx 21% · 5h 73% · 7d 12%"
check "no HOME/USER: silent stderr" "$(cat "$work/err")" ""

# --- default destination must track the overlay's bundle identifier -------
# Producer and consumer agree on the path by convention alone, so a rename of
# one side is otherwise silent: the gauge simply never sees a reading.
identifier=$(jq -r '.identifier' "$here/../src-tauri/tauri.conf.json")
# shellcheck disable=SC2016  # sed pattern: the default must stay unexpanded.
wsl_default=$(sed -n 's/^ *KLEPSYDRA_DIR="\(\/mnt\/c\/.*\)"$/\1/p' "$script")
# Both halves read out of a file, so both can come back empty -- and two empty
# strings compare equal, which would pass this test by reading nothing at all.
check "identifier is readable"  "$([[ -n "$identifier" ]] && echo yes)"  "yes"
check "WSL default is readable" "$([[ -n "$wsl_default" ]] && echo yes)" "yes"
# The whole path, not just its last component: Roaming instead of Local, or the
# install dir with the identifier appended, both end in the right name.
# $USER is compared unexpanded: the hook resolves it at run time, per user.
# shellcheck disable=SC2016  # that is the point: the literal, not this user's.
check "WSL default is the Windows app data dir" "$wsl_default" \
  '/mnt/c/Users/$USER/AppData/Local/'"$identifier"

# --- the Linux default, exercised rather than read -------------------------
# Tauri's app_local_data_dir: $XDG_DATA_HOME when absolute, else ~/.local/share.
# Skipped under WSL, where the default deliberately points at the Windows side.
osrelease=""
{ read -r osrelease </proc/sys/kernel/osrelease; } 2>/dev/null
if [[ "$osrelease" == *[Mm]icrosoft* ]]; then
  echo "  skip default-dir runs (WSL)"
else
  linux_run() { # extra env assignments...
    (cd "$work" && env -u KLEPSYDRA_DIR -u XDG_DATA_HOME CLAUDE_CONFIG_DIR="$work/team" \
      HOME="$work/home" "$@" bash "$script" <"$fixtures/full.json" >/dev/null)
  }
  landed() { jq -r '.account' "$1/$identifier/accounts/uuid-team/abc-123.json" 2>/dev/null; }

  linux_run XDG_DATA_HOME="$work/xdg"
  check "Linux: absolute XDG_DATA_HOME honoured" "$(landed "$work/xdg")" "uuid-team"
  linux_run
  check "Linux: unset falls back to ~/.local/share" "$(landed "$work/home/.local/share")" "uuid-team"
  rm -rf "${work:?}/home"
  linux_run XDG_DATA_HOME=rel
  check "Linux: relative XDG_DATA_HOME ignored" "$(landed "$work/home/.local/share")" "uuid-team"
  check "Linux: nothing under the working dir" "$([[ -e "$work/rel" ]] && echo leaked || echo clean)" "clean"
fi

# --- a reading with no live window is never published ----------------------
# A real response always reports the window it counts against, so a reading
# whose every window has ended is a re-render of an old one.
rm -rf "$work/out"
KLEPSYDRA_NOW=1789500000 run full.json team >/dev/null
check "every window ended: publishes nothing" "$([[ -e $work/out/accounts ]] && echo leaked || echo clean)" "clean"
display=$(KLEPSYDRA_NOW=1789500000 run full.json team)
check "every window ended: still echoes" "$display" "Opus 5 · ctx 21% · 5h 73% · 7d 12%"
KLEPSYDRA_NOW=1789100000 run full.json team >/dev/null
check "one window still live: published" "$(jq -r '.windows.seven_day.used_percentage' "$(acct uuid-team)")" "12.9"
rm -rf "$work/out"
KLEPSYDRA_NOW=1789500000 run_json "$(jq -c 'del(.rate_limits.seven_day) | del(.rate_limits.five_hour.resets_at)' <<<"$full")" team >/dev/null
check "a window with no reset time counts as live" "$(jq -r '.windows.five_hour.used_percentage' "$(acct uuid-team)")" "73.2"

# --- readings the gauge can never draw again are pruned ----------------------
P=1790000000 day=86400
pd="$work/p/dev.ajsoftworks.klepsydra"
pa="$pd/accounts"
u() { printf '%08d-0000-4000-8000-000000000000' "$1"; } # n -> a session uuid
reading() { # account, n, stamp, five_hour resets_at [seven_day resets_at]
  mkdir -p "$pa/$1"
  jq -nc --arg a "$1" --arg s "$(u "$2")" --argjson at "$3" --argjson r5 "$4" --argjson r7 "${5:-null}" '
    {account: $a, label: "L", session: $s, written_at: $at, observed_at: $at,
     windows: ({five_hour: {used_percentage: 5, resets_at: $r5}}
       + if $r7 == null then {} else {seven_day: {used_percentage: 9, resets_at: $r7}} end)}' \
    >"$pa/$1/$(u "$2").json"
}
there() { [[ -e $pa/$1 ]] && echo kept || echo gone; } # path under accounts
live=$(jq -c --argjson r "$((P + 3600))" '.session_id = "'"$(u 99)"'"
  | .rate_limits.five_hour.resets_at = $r | .rate_limits.seven_day.resets_at = ($r + 86400)' <<<"$full")
# The prune runs detached; its lock is free once it is done.
settle() { flock "$XDG_RUNTIME_DIR/klepsydra-readings-$UID.lock" true; }
prune_run() { # epoch-seconds [json]
  CLAUDE_CONFIG_DIR="$work/team" KLEPSYDRA_DIR="$pd" KLEPSYDRA_NOW="$1" bash "$script" <<<"${2:-$live}"
  settle
}
layout() {
  rm -rf "$work/p" "${XDG_RUNTIME_DIR:?}"/*
  reading uuid-team 1 $((P - 3 * day)) $((P - 2 * day))              # newest, ended
  reading uuid-team 2 $((P - 5 * day)) $((P - 4 * day))              # older, ended
  reading uuid-team 3 $((P - 5 * day)) $((P - day / 2))              # ended only 12 h ago
  reading uuid-team 4 $((P - 5 * day)) $((P - 4 * day)) $((P + day)) # one window live
  reading uuid-team 5 $((P - 5 * day)) $((P - 4 * day))
  jq -c 'del(.windows.five_hour.resets_at)' "$pa/uuid-team/$(u 5).json" >"$work/x" && mv "$work/x" "$pa/uuid-team/$(u 5).json"
  printf '{"account":' >"$pa/uuid-team/$(u 6).json"                 # does not parse
  reading uuid-team 7 $((P - 5 * day)) $((P - 4 * day))
  line=$(cat "$pa/uuid-team/$(u 7).json")
  printf '%s\n' "$line" >>"$pa/uuid-team/$(u 7).json"               # two lines
  reading uuid-team 8 "null" $((P - 4 * day))                        # no stamp
  cp "$pa/uuid-team/$(u 2).json" "$pa/uuid-team/abc-123.json"        # not a uuid
  reading uuid-gone 1 $((P - 31 * day)) $((P - 30 * day))            # account dropped
  reading uuid-gone 2 $((P - 32 * day)) $((P - 31 * day))
  reading uuid-held 1 $((P - 29 * day)) $((P - 28 * day))            # newest, not dropped
  reading uuid-held 2 $((P - 30 * day)) $((P - 29 * day))
  # Outside the folder, an older ended reading beside its newer one.
  reading outside 1 $((P - 3 * day)) $((P - 2 * day))
  reading outside 2 $((P - 5 * day)) $((P - 4 * day))
  mv "$pa/outside" "$work/p/outside"
  ln -s ../../outside "$pa/linked"                                  # a link to a folder
  ln -s "../../../outside/$(u 2).json" "$pa/uuid-team/$(u 9).json"  # a link to a file
  : >"$pa/uuid-team/$(u 2).json.123.tmp"; touch -d @$((P - 2 * day)) "$pa/uuid-team/$(u 2).json.123.tmp"
  : >"$pa/uuid-team/$(u 2).json.456.tmp"; touch -d @$((P - 3600)) "$pa/uuid-team/$(u 2).json.456.tmp"
  printf '{}\n' >"$pa/old-flat.json"                                # a pre-per-session file
}
# What the gauge draws, at the prune's clock, from the readings the overlay
# reads: each <account>/*.json that parses as one value, links followed.
rows() {
  local f
  for f in "$pa"/*/*.json; do
    jq -cs 'if length == 1 then .[0] else empty end' "$f" 2>/dev/null
  done | jq -cs '[.[] | objects]' |
    node --input-type=module -e '
      const { toRows } = await import(process.argv[1]);
      let s = ""; for await (const c of process.stdin) s += c;
      console.log(JSON.stringify(toRows(JSON.parse(s), Number(process.argv[2]) * 1000)));
    ' "$here/../src/gauge.js" "$P" 2>&1
}
# The render publishes nothing here, so the rows before and after compare.
layout
before=$(command -v node >/dev/null && rows)
display=$(prune_run $P "$(jq -c 'del(.rate_limits)' <<<"$live")")
check "prune: still echoes" "$display" "Opus 5 · ctx 21%"
check "prune: the account's newest stays" "$(there "uuid-team/$(u 1).json")" "kept"
check "prune: an older reading whose windows ended over a day ago goes" "$(there "uuid-team/$(u 2).json")" "gone"
check "prune: a window ended under a day ago keeps it" "$(there "uuid-team/$(u 3).json")" "kept"
check "prune: a live window keeps it" "$(there "uuid-team/$(u 4).json")" "kept"
check "prune: a window with no reset time keeps it" "$(there "uuid-team/$(u 5).json")" "kept"
check "prune: a file that does not parse stays" "$(there "uuid-team/$(u 6).json")" "kept"
check "prune: a file of two lines stays" "$(there "uuid-team/$(u 7).json")" "kept"
check "prune: a reading with no stamp stays" "$(there "uuid-team/$(u 8).json")" "kept"
check "prune: a name that is not a uuid stays" "$(there "uuid-team/abc-123.json")" "kept"
check "prune: a dropped account goes whole" "$(there uuid-gone)" "gone"
check "prune: an account heard within 30 days keeps its newest" "$(there "uuid-held/$(u 1).json")" "kept"
check "prune: and loses its older ended reading" "$(there "uuid-held/$(u 2).json")" "gone"
check "prune: nothing through a link to a folder" "$([[ -e $work/p/outside/$(u 2).json ]] && echo kept || echo gone)" "kept"
check "prune: a link to a file stays" "$([[ -L $pa/uuid-team/$(u 9).json ]] && echo kept || echo gone)" "kept"
check "prune: and so does its target" "$([[ -e $pa/uuid-team/$(u 9).json ]] && echo kept || echo gone)" "kept"
check "prune: write litter a day old goes" "$(there "uuid-team/$(u 2).json.123.tmp")" "gone"
check "prune: fresh write litter stays" "$(there "uuid-team/$(u 2).json.456.tmp")" "kept"
check "prune: a pre-per-session file stays" "$(there old-flat.json)" "kept"
if command -v node >/dev/null; then
  after=$(rows)
  check "prune: the gauge draws the same rows" "$after" "$before"
  check "prune: and draws some" "$([[ $after == '[{'* ]] && echo yes || echo "$after")" "yes"
else
  echo "  skip gauge rows: no node"
fi

# A pruned session that renders again cannot bring its old reading back.
again=$(jq -c --arg s "$(u 2)" --argjson r $((P - 4 * day)) '.session_id = $s
  | .rate_limits = {five_hour: {used_percentage: 5, resets_at: $r}}' <<<"$full")
prune_run $((P + 60)) "$again" >/dev/null
check "prune: a pruned session's re-render publishes nothing" "$(there "uuid-team/$(u 2).json")" "gone"

# At most once an hour. A render's reading is published before the prune, and
# as the account's newest it retires the reading that was.
reading uuid-team 2 $((P - 5 * day)) $((P - 4 * day))
prune_run $((P + 1800)) >/dev/null
check "prune: not again within the hour" "$(there "uuid-team/$(u 2).json")" "kept"
check "prune: this render published" "$(there "uuid-team/$(u 99).json")" "kept"
prune_run $((P + 3600)) >/dev/null
check "prune: again an hour on" "$(there "uuid-team/$(u 2).json")" "gone"
check "prune: a newer reading retires the ended newest" "$(there "uuid-team/$(u 1).json")" "gone"

# Only in the overlay's own data dir.
layout
mv "$work/p/dev.ajsoftworks.klepsydra" "$work/p/klepsydra-copy"
CLAUDE_CONFIG_DIR="$work/team" KLEPSYDRA_DIR="$work/p/klepsydra-copy" KLEPSYDRA_NOW=$P bash "$script" <<<"$live" >/dev/null
settle
check "prune: nothing in another folder" "$([[ -e $work/p/klepsydra-copy/accounts/uuid-gone ]] && echo kept || echo gone)" "kept"
check "prune: and no stamp for it" "$(find "$XDG_RUNTIME_DIR" -name '*.pruned' | wc -l)" "0"

# A render does not wait for the prune, and a prune already running is left to
# finish alone.
layout
exec {held}>>"$XDG_RUNTIME_DIR/klepsydra-readings-$UID.lock"; flock "$held"
start=$(date +%s%N)
display=$(prune_run_nowait() { CLAUDE_CONFIG_DIR="$work/team" KLEPSYDRA_DIR="$pd" KLEPSYDRA_NOW=$P bash "$script" <<<"$live"; }; prune_run_nowait)
took=$(( ($(date +%s%N) - start) / 1000000 ))
check "prune: a locked prune is skipped" "$(there "uuid-team/$(u 2).json")" "kept"
exec {held}>&-
check "prune: and the render echoes" "$display" "Opus 5 · ctx 21% · 5h 73% · 7d 12%"
layout
start=$(date +%s%N)
CLAUDE_CONFIG_DIR="$work/team" KLEPSYDRA_DIR="$pd" KLEPSYDRA_NOW=$P bash "$script" <<<"$live" >/dev/null
took=$(( ($(date +%s%N) - start) / 1000000 ))
settle
check "prune: done once its lock is free" "$(there "uuid-team/$(u 2).json")" "gone"
check "prune: a render returns before it ($took ms)" "$(( took < 1000 ))" "1"

block() { sed -n '/^# --- prune helpers/,/^# --- end prune helpers ---$/p' "$1"; }
check "prune helpers present" "$([[ -n "$(block "$script")" ]] && echo yes)" "yes"
check "prune helpers identical in the fleet hook" "$(block "$script")" "$(block "$here/../hooks/klepsydra-fleet.sh")"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
