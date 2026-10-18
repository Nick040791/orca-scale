#!/usr/bin/env bash
# Launch Orca from the dev checkout: build if stale, then run the built app.
# Exec target of ~/Desktop/Orca.desktop. Log: ~/.cache/orca-launcher/launch.log
set -euo pipefail

# Resolve the checkout from this script's location so the launcher works no
# matter where the repo lives (override with ORCA_REPO=...).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCA_REPO="${ORCA_REPO:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
# GNOME launches .desktop entries without .bashrc, so pnpm's bin dir is not on
# the session PATH. Export it here; node lives in ~/.local/bin (from .profile).
# Prefer an installed Node 24 over the newer ~/.local/bin node to avoid native
# rebuilds and Node deprecation warnings.
export PATH="$HOME/.local/share/pnpm/bin:$HOME/.local/bin:$PATH"
if [ -d "$HOME/.nvm/versions/node" ]; then
  NODE24_DIR="$(ls -d "$HOME/.nvm/versions/node"/v24.* 2>/dev/null | sort -V | tail -1)"
  if [ -n "$NODE24_DIR" ] && [ -x "$NODE24_DIR/bin/node" ]; then
    export PATH="$NODE24_DIR/bin:$PATH"
  fi
fi

# ELECTRON_RUN_AS_NODE leaks from Electron-based hosts and would boot Electron
# as plain Node (same hazard run-electron-vite-dev.mjs guards against).
unset ELECTRON_RUN_AS_NODE

cd "$ORCA_REPO"

# Orca's supported Node runtime is 24 (see package.json engines). A newer
# host Node forces native deps to rebuild from source and emits deprecation
# noise. Prefer nvm's Node 24 when available.
if [ -s "$HOME/.nvm/nvm.sh" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.nvm/nvm.sh"
  nvm use 24 >/dev/null 2>&1 || true
fi

mkdir -p "$HOME/.cache/orca-launcher"
LOG="$HOME/.cache/orca-launcher/launch.log"
exec > >(tee -a "$LOG") 2>&1

# One click at a time: a double click would otherwise stack two electron-vite
# processes writing out/ concurrently. The app's single-instance lock only
# dedupes running apps, not builds.
lockdir="$HOME/.cache/orca-launcher/launch.lock"
if ! mkdir "$lockdir" 2>/dev/null; then
  echo "[launcher] Orca build/launch already in progress; exiting."
  exit 0
fi
trap 'rmdir "$lockdir" 2>/dev/null' EXIT

# ---------- 1. Build if stale ----------
STAMP="$HOME/.cache/orca-launcher/build.stamp"

need_build=0
if [ ! -f out/renderer/index.html ] || [ ! -f out/main/index.js ]; then
  need_build=1
elif [ -f "$STAMP" ] && [ -n "$(find src config package.json electron.vite.config.ts pnpm-lock.yaml -newer "$STAMP" -print -quit 2>/dev/null)" ]; then
  echo "[launcher] Sources changed since last build."
  need_build=1
fi

if [ "$need_build" -eq 1 ]; then
  echo "[launcher] Building Orca (first build can take several minutes)..."
  pnpm run ensure:electron-runtime
  pnpm run build:electron-vite
  date +%s > "$STAMP"
else
  echo "[launcher] out/ up to date; skipping build."
fi

# ---------- 2. Launch the built app ----------
ELECTRON_BIN="$ORCA_REPO/node_modules/.bin/electron"
if [ ! -x "$ELECTRON_BIN" ]; then
  echo "[launcher] Electron not installed; run: pnpm install" >&2
  exit 1
fi

# Chromium aborts at startup unless the SUID sandbox helper is root-owned 4755
# (a fresh pnpm install resets it). Mirror the packaging contract in
# resources/linux/packaging/after-install.sh.
# The .bin/electron shim is a wrapper script, not a symlink, so resolve the
# real dist dir the way Node does; pnpm-glob as fallback.
ELECTRON_REAL="$(node -e "console.log(require('electron'))" 2>/dev/null || true)"
if [ -n "$ELECTRON_REAL" ] && [ -x "$ELECTRON_REAL" ]; then
  SANDBOX="$(dirname "$ELECTRON_REAL")/chrome-sandbox"
else
  dist_dirs=(node_modules/.pnpm/electron@*/node_modules/electron/dist)
  SANDBOX="${dist_dirs[0]}/chrome-sandbox"
fi
if [ -f "$SANDBOX" ] && [ ! -u "$SANDBOX" ]; then
  if sudo -n chown root:root "$SANDBOX" && sudo -n chmod 4755 "$SANDBOX"; then
    echo "[launcher] Fixed chrome-sandbox SUID permissions."
  else
    echo "[launcher] WARNING: chrome-sandbox needs: sudo chown root:root $SANDBOX && sudo chmod 4755 $SANDBOX" >&2
  fi
fi

# Detach: the launcher exits after the app starts and the lock is released;
# a second click then just re-hits the app's own single-instance lock.
# "--" fences extra args: Electron forwards everything after the app path
# to the app, and a bare "-x" would otherwise be eaten as a Chromium switch.
echo "[launcher] Starting Orca..."
setsid -f "$ELECTRON_BIN" . -- "$@" >/dev/null 2>&1
