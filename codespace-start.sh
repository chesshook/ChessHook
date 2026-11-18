#!/usr/bin/env bash
# Start/restart the Stockfish API process inside a running GitHub Codespace.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="$ROOT/.cache/chesshook"
TOKEN_FILE="$ROOT/.secrets/api-token"
ENV_FILE="$CACHE/engine.env"
ENGINE_BIN="$CACHE/Stockfish/src/stockfish"
PID_FILE="$ROOT/codespace-api.pid"
LOG_FILE="$ROOT/codespace-api.log"

log() { printf '[chesshook-codespace] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ -x "$ENGINE_BIN" ]] || die 'Stockfish binary missing; run bash ./codespace.sh first.'
[[ -s "$TOKEN_FILE" ]] || die 'API token missing; run bash ./codespace.sh first.'
[[ -s "$ENV_FILE" ]] || die 'Engine resource config missing; run bash ./codespace.sh first.'

set -a
. "$ENV_FILE"
set +a
API_TOKEN="$(cat "$TOKEN_FILE")"

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

nohup env \
  SF_ENGINE="$ENGINE_BIN" \
  SF_THREADS="$SF_THREADS" \
  SF_HASH_MB="$SF_HASH_MB" \
  SF_MAX_MOVETIME_MS=30000 \
  SF_BIND_HOST=0.0.0.0 \
  CHESSHOOK_API_TOKEN="$API_TOKEN" \
  python3 "$ROOT/engine_api.py" \
  > "$LOG_FILE" 2>&1 </dev/null &
API_PID=$!
printf '%s\n' "$API_PID" > "$PID_FILE"
chmod 0600 "$PID_FILE"

HEALTH_OK=0
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8765/healthz >/dev/null 2>&1; then HEALTH_OK=1; break; fi
  if ! kill -0 "$API_PID" 2>/dev/null; then
    tail -n 80 "$LOG_FILE" || true
    die 'Stockfish API process exited during startup.'
  fi
  sleep 1
done
((HEALTH_OK == 1)) || { tail -n 80 "$LOG_FILE" || true; die 'Local health check timed out.'; }

log "Stockfish API is running: threads=$SF_THREADS, Hash=$SF_HASH_MB MiB."
printf 'Health check: http://localhost:8765/healthz\n'
printf 'Analysis API: http://localhost:8765/v1/analyze\n'
