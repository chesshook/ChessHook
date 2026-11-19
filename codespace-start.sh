#!/usr/bin/env bash
# Start/restart the Stockfish API inside a running GitHub Codespace.
# The API listens only on loopback; Tailscale Serve exposes it privately to the tailnet.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
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
  SF_BIND_HOST=127.0.0.1 \
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

log "Stockfish API is running on loopback: threads=$SF_THREADS, Hash=$SF_HASH_MB MiB."

# The official Tailscale Codespaces feature reads the Codespaces secret TS_AUTH_KEY.
# Never place an auth key in this script or in the repository.
if command -v tailscale >/dev/null 2>&1; then
  if [[ "$EUID" -eq 0 ]] || ! command -v sudo >/dev/null 2>&1; then
    TS_CMD="tailscale"
  else
    TS_CMD="sudo tailscale"
  fi
  if $TS_CMD status >/dev/null 2>&1; then
    if $TS_CMD serve --bg http://127.0.0.1:8765 >/dev/null; then
      log 'Private Tailscale Serve is configured.'
      $TS_CMD serve status || true
    else
      log 'WARNING: Tailscale is connected, but Serve setup failed. Check tailnet HTTPS certificate settings and tailscale serve status.'
    fi
  else
    log 'WARNING: Tailscale daemon is installed but not authenticated. Add the Codespaces secret TS_AUTH_KEY and rebuild the devcontainer.'
  fi
else
  log 'WARNING: Tailscale CLI is missing. Add the Codespaces Tailscale feature and rebuild the devcontainer.'
fi

printf 'Local health check: http://127.0.0.1:8765/healthz\n'
printf 'Local analysis API: http://127.0.0.1:8765/v1/analyze\n'
printf 'Keep Codespaces port 8765 private; use the HTTPS URL printed by tailscale serve status in ChessHook.\n'
