#!/usr/bin/env bash
# Mirror a checkout to an NTFS stage and run the readcost example there.
# usage: winrun.sh <checkout> <stage-name> <calls>
set -euo pipefail
src=$1 name=$2 calls=${3:-50}
[[ $name =~ ^klepsydra-build-[A-Za-z0-9._-]+$ ]] || { echo bad stage; exit 2; }
stage=/mnt/c/Users/ajbar/$name
mkdir -p "$stage"
rsync -a --delete --exclude 'src-tauri/target/' --exclude 'node_modules/' --exclude '.git/' "$src"/ "$stage"/
# shellcheck disable=SC2016  # PowerShell source: $env: must reach pwsh unexpanded.
tools='$env:Path = "$env:USERPROFILE\.cargo\bin;" + $env:Path'
powershell.exe -NoProfile -Command "$tools; cd 'C:\Users\ajbar\\$name\src-tauri'; cargo run -q --release -p klepsydra-fleet --example readcost -- 'C:\Users\ajbar\klepsydra-perf\data-1119' $calls; exit \$LASTEXITCODE" 2>&1 | tr -d '\r'
