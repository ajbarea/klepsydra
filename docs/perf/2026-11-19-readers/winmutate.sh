#!/usr/bin/env bash
# Mutations of the Windows listing, run natively on an NTFS stage that
# scripts/build-windows.sh --check has mirrored. Each must fail the suite.
# usage: winmutate.sh <stage-name>
set -uo pipefail
name=${1:?stage name}
[[ $name =~ ^klepsydra-build-[A-Za-z0-9._-]+$ ]] || { echo bad stage; exit 2; }
memo=/mnt/c/Users/ajbar/$name/src-tauri/fleet/src/memo.rs
[[ -f $memo ]] || { echo "no $memo"; exit 2; }
# shellcheck disable=SC2016  # PowerShell source: $env: must reach pwsh unexpanded.
tools='$env:Path = "$env:USERPROFILE\.cargo\bin;" + $env:Path'
run() {
  powershell.exe -NoProfile -Command "$tools; cd 'C:\Users\ajbar\\$name\src-tauri'; cargo test -q -p klepsydra-fleet --lib; exit \$LASTEXITCODE" >/dev/null 2>&1
}
# name | old | new  (each old must occur exactly once)
muts=(
  "change time is the write time|changed: time(e.ChangeTime),|changed: time(e.LastWriteTime),"
  "handle change time is the write time|changed: time(basic.ChangeTime),|changed: time(basic.LastWriteTime),"
  "listing file id dropped|id: e.FileId as u64,|id: 0,"
  "listing length dropped|len: e.EndOfFile as u64,|len: 0,"
  "junction read as the folder it names|tag & 0x2000_0000 != 0|tag & 0 != 0"
)
orig=$(cat "$memo")
# Put the file back however the script ends (a timeout included).
trap 'printf "%s\n" "$orig" >"$memo"' EXIT
trap "exit 143" TERM INT
run || { echo "baseline fails"; exit 1; }
echo "baseline: pass"
for m in "${muts[@]}"; do
  IFS='|' read -r what old new <<<"$m"
  n=$(grep -cF -- "$old" "$memo")
  [[ $n == 1 ]] || { echo "anchor x$n: $what"; continue; }
  python3 -c 'import sys; p,o,n=sys.argv[1:]; s=open(p).read(); open(p,"w").write(s.replace(o,n))' "$memo" "$old" "$new"
  start=$SECONDS
  if run; then v=SURVIVED; else v=KILLED; fi
  echo "$v: $what ($((SECONDS - start)) s)"
  printf '%s\n' "$orig" >"$memo"
done
