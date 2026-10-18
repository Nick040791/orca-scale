#!/usr/bin/env bash
# Sync the current branch with upstream/main while preserving local custom settings.
set -euo pipefail

git fetch upstream
if git merge --no-edit -X theirs upstream/main; then
  echo "[sync] Merge completed cleanly."
else
  echo "[sync] Conflicts remain; resolve them, then commit." >&2
  exit 1
fi