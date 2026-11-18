#!/usr/bin/env bash
# Install/build/run Stockfish 19 directly in a GitHub Codespace.
# Run from the repository root: bash ./codespace.sh
set -Eeuo pipefail

log() { printf '\n[chesshook-codespace] %s\n' "$*"; }
die() { printf '\n[chesshook-codespace] ERROR: %s\n' "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$ROOT/engine_api.py" ]] || die 'Run this from the ChessHook repository; engine_api.py is missing.'
[[ -n "${CODESPACES:-}" || -n "${CODESPACE_NAME:-}" ]] || log 'Codespaces environment marker not detected; continuing as a compatible Linux workspace.'
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  APT_PREFIX=()
elif command -v sudo >/dev/null 2>&1; then
  APT_PREFIX=(sudo)
else
  die 'Package installation requires root or sudo.'
fi

export DEBIAN_FRONTEND=noninteractive
"${APT_PREFIX[@]}" apt-get update
"${APT_PREFIX[@]}" apt-get install -y --no-install-recommends ca-certificates curl git build-essential python3

NCPU="$(nproc)"
THREADS="$NCPU"
((THREADS < 1)) && THREADS=1

# Respect visible cgroup v2 CPU quota if the workspace has one.
if [[ -r /sys/fs/cgroup/cpu.max ]]; then
  read -r CPU_QUOTA_RAW CPU_PERIOD_RAW < /sys/fs/cgroup/cpu.max
  if [[ "$CPU_QUOTA_RAW" =~ ^[0-9]+$ && "$CPU_PERIOD_RAW" =~ ^[0-9]+$ && "$CPU_PERIOD_RAW" -gt 0 ]]; then
    QUOTA_CPUS=$((CPU_QUOTA_RAW / CPU_PERIOD_RAW))
    ((QUOTA_CPUS < 1)) && QUOTA_CPUS=1
    ((QUOTA_CPUS < THREADS)) && THREADS="$QUOTA_CPUS"
  fi
fi

# Effective available RAM = min(/proc/meminfo MemAvailable, remaining cgroup memory).
MEM_BYTES=$(( $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) * 1024 ))
CG2_REL="$(awk -F: '$1 == 0 {print $3; exit}' /proc/self/cgroup 2>/dev/null || true)"
if [[ -n "$CG2_REL" ]]; then
  CG_DIR="/sys/fs/cgroup$CG2_REL"
  while [[ "$CG_DIR" == /sys/fs/cgroup* ]]; do
    if [[ -r "$CG_DIR/memory.max" && -r "$CG_DIR/memory.current" ]]; then
      MAX="$(cat "$CG_DIR/memory.max")"
      CUR="$(cat "$CG_DIR/memory.current")"
      if [[ "$MAX" =~ ^[0-9]+$ && "$CUR" =~ ^[0-9]+$ ]]; then
        LEFT=$((MAX > CUR ? MAX - CUR : 0))
        ((LEFT < MEM_BYTES)) && MEM_BYTES="$LEFT"
      fi
    fi
    [[ "$CG_DIR" == /sys/fs/cgroup ]] && break
    CG_DIR="$(dirname "$CG_DIR")"
  done
fi
MEM_MB=$((MEM_BYTES / 1048576))
((MEM_MB >= 2048)) || die "Only $MEM_MB MiB effective free memory is visible; need at least 2048 MiB for a safe engine run."
# Allocate at most 65% of presently available memory to the Stockfish hash.
HASH_MB=$((MEM_MB * 65 / 100))
HASH_MB=$((HASH_MB / 256 * 256))
((HASH_MB < 512)) && HASH_MB=512
((HASH_MB > 4096)) && HASH_MB=4096

CACHE="$ROOT/.cache/chesshook"
ENGINE_DIR="$CACHE/Stockfish"
ENGINE_BIN="$ENGINE_DIR/src/stockfish"
mkdir -p "$CACHE"

if [[ ! -x "$ENGINE_BIN" ]]; then
  if [[ -d "$ENGINE_DIR/.git" ]]; then
    log 'Refreshing existing Stockfish checkout to official tag sf_19.'
    git -c safe.directory="$ENGINE_DIR" -C "$ENGINE_DIR" remote set-url origin https://github.com/official-stockfish/Stockfish.git
    git -c safe.directory="$ENGINE_DIR" -C "$ENGINE_DIR" fetch --depth=1 origin tag sf_19
    git -c safe.directory="$ENGINE_DIR" -C "$ENGINE_DIR" checkout --force sf_19
  else
    rm -rf "$ENGINE_DIR"
    log 'Cloning official Stockfish 19 source.'
    git clone --depth=1 --branch sf_19 https://github.com/official-stockfish/Stockfish.git "$ENGINE_DIR"
  fi
  log "Compiling Stockfish 19 natively with $THREADS jobs."
  make -C "$ENGINE_DIR/src" -j"$THREADS" build ARCH=native
fi
[[ -x "$ENGINE_BIN" ]] || die 'Stockfish binary was not produced.'

UCI_CHECK="$(printf 'uci\nisready\nquit\n' | timeout 30 "$ENGINE_BIN" 2>&1 || true)"
grep -q 'uciok' <<<"$UCI_CHECK" || die 'Stockfish UCI handshake failed (uciok missing).'
grep -q 'readyok' <<<"$UCI_CHECK" || die 'Stockfish readiness check failed (readyok missing).'

# Keep generated credentials, binaries, and logs out of Git.
mkdir -p "$ROOT/.secrets"
chmod 0700 "$ROOT/.secrets"
touch "$ROOT/.gitignore"
for entry in '.secrets/' '.cache/' 'codespace-api.log' 'codespace-api.pid' '__pycache__/' '*.pyc'; do
  grep -qxF "$entry" "$ROOT/.gitignore" || printf '%s\n' "$entry" >> "$ROOT/.gitignore"
done
cat > "$CACHE/engine.env" <<ENV
SF_THREADS=$THREADS
SF_HASH_MB=$HASH_MB
ENV
chmod 0600 "$CACHE/engine.env"

TOKEN_FILE="$ROOT/.secrets/api-token"
TOKEN_CREATED=0
if [[ ! -s "$TOKEN_FILE" ]]; then
  python3 -c 'import secrets; print(secrets.token_urlsafe(48))' > "$TOKEN_FILE"
  TOKEN_CREATED=1
fi
chmod 0600 "$TOKEN_FILE"
API_TOKEN="$(cat "$TOKEN_FILE")"
[[ ${#API_TOKEN} -ge 40 ]] || die 'Saved API token is unexpectedly short.'

log "Starting Codespaces API: $THREADS thread(s), Hash=$HASH_MB MiB."
bash "$ROOT/codespace-start.sh"

if [[ "$TOKEN_CREATED" -eq 1 ]]; then
  printf '\nNEW API BEARER TOKEN (save it in your client; it is not committed):\n%s\n' "$API_TOKEN"
else
  printf '\nAPI bearer token reused from %s/.secrets/api-token\n' "$ROOT"
fi
printf 'Resources:    %s vCPU thread(s), Hash=%s MiB, effective available RAM=%s MiB\\n' "$THREADS" "$HASH_MB" "$MEM_MB"
printf 'API logs:     %s/codespace-api.log\\n' "$ROOT"
printf 'Stop API:     kill "$(cat %s/codespace-api.pid)"\\n' "$ROOT"
printf '\nOpen the Codespaces PORTS panel and keep port 8765 Private.\n'
