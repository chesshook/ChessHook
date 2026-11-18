#!/usr/bin/env bash
# Install/build/run Stockfish 19 directly in a GitHub Codespace.
# Run from the repository root: bash ./codespace.sh
set -Eeuo pipefail

log() { printf '\n[chesshook-codespace] %s\n' "$*"; }
die() { printf '\n[chesshook-codespace] ERROR: %s\n' "$*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$ROOT/engine_api.py" ]] || die 'Run this from the ChessHook repository; engine_api.py is missing.'
[[ -n "${CODESPACES:-}" || -n "${CODESPACE_NAME:-}" ]] || log 'Codespaces environment marker not detected; continuing as a compatible Linux workspace.'
[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Run as root in this Codespace so build packages can be installed.'

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git build-essential python3

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
TOKEN_FILE="$ROOT/.secrets/api-token"
TOKEN_CREATED=0
if [[ ! -s "$TOKEN_FILE" ]]; then
  python3 -c 'import secrets; print(secrets.token_urlsafe(48))' > "$TOKEN_FILE"
  TOKEN_CREATED=1
fi
chmod 0600 "$TOKEN_FILE"
API_TOKEN="$(cat "$TOKEN_FILE")"
[[ ${#API_TOKEN} -ge 40 ]] || die 'Saved API token is unexpectedly short.'

# Stop only the API process previously started by this script.
PID_FILE="$ROOT/codespace-api.pid"
if [[ -s "$PID_FILE" ]]; then
  OLD_PID="$(cat "$PID_FILE")"
  if [[ "$OLD_PID" =~ ^[0-9]+$ ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    OLD_CMD="$(tr '\0' ' ' < "/proc/$OLD_PID/cmdline" 2>/dev/null || true)"
    if [[ "$OLD_CMD" == *"$ROOT/engine_api.py"* ]]; then
      kill "$OLD_PID" 2>/dev/null || true
      for _ in $(seq 1 10); do
        kill -0 "$OLD_PID" 2>/dev/null || break
        sleep 1
      done
    fi
  fi
fi

log "Launching Stockfish API: $THREADS thread(s), Hash=$HASH_MB MiB."
nohup env \
  SF_ENGINE="$ENGINE_BIN" \
  SF_THREADS="$THREADS" \
  SF_HASH_MB="$HASH_MB" \
  SF_MAX_MOVETIME_MS=30000 \
  SF_BIND_HOST=0.0.0.0 \
  CHESSHOOK_API_TOKEN="$API_TOKEN" \
  python3 "$ROOT/engine_api.py" \
  > "$ROOT/codespace-api.log" 2>&1 </dev/null &
API_PID=$!
printf '%s\n' "$API_PID" > "$PID_FILE"
chmod 0600 "$PID_FILE"

HEALTH_OK=0
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8765/healthz >/dev/null 2>&1; then HEALTH_OK=1; break; fi
  if ! kill -0 "$API_PID" 2>/dev/null; then
    tail -n 80 "$ROOT/codespace-api.log" || true
    die 'Stockfish API process exited during startup.'
  fi
  sleep 1
done
((HEALTH_OK == 1)) || { tail -n 80 "$ROOT/codespace-api.log" || true; die 'Local health check timed out.'; }

log 'Codespaces Stockfish API is running.'
printf '\nHealth check: http://localhost:8765/healthz\n'
printf 'Analysis API: http://localhost:8765/v1/analyze\n'
printf 'Resources:    %s vCPU thread(s), Hash=%s MiB, effective available RAM=%s MiB\n' "$THREADS" "$HASH_MB" "$MEM_MB"
if [[ "$TOKEN_CREATED" -eq 1 ]]; then
  printf '\nNEW API BEARER TOKEN (save it in your client; it is not committed):\n%s\n' "$API_TOKEN"
else
  printf '\nAPI bearer token reused from %s/.secrets/api-token\n' "$ROOT"
fi
printf '\nAPI logs:     %s/codespace-api.log\n' "$ROOT"
printf 'Stop API:     kill "$(cat %s/codespace-api.pid)"\n' "$ROOT"
printf '\nOpen the Codespaces PORTS panel and keep port 8765 Private.\n'
