#!/usr/bin/env bash
# Sync the read-only source mount (/src) into the container-local build tree
# (/work). Build artifacts and caches are excluded so a re-sync never clobbers
# container-local state, and nothing here ever writes back to /src. `.native`
# stays container-local too: the CLI regenerates each zero-config app's build
# graph in /work/examples/<app>/.native/build and its zig cache lives inside.
set -eu
rsync -a --delete \
  --exclude '.git' \
  --exclude '.zig-cache' \
  --exclude '.native' \
  --exclude 'zig-out' \
  --exclude 'node_modules' \
  --exclude 'evals/' \
  --exclude '.claude/' \
  /src/ /work/
echo "synced /src -> /work"
