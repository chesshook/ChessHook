#!/usr/bin/env bash
# Runtime entrypoint for the Podman/container deployment (no systemd or /dev/net/tun).
set -Eeuo pipefail

BASE=/config/chesshook
SOCKET=/run/tailscale/tailscaled.sock
STATE_DIR="$BASE/tailscale-state"
KEY_FILE="$BASE/ts-auth-key"
LOG="$BASE/tailscaled.log"

log() { printf '[chesshook-container] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Run container-run.sh as root.'
[[ -x /usr/sbin/tailscaled || -x /usr/bin/tailscaled ]] || die 'Tailscale daemon is not installed.'
[[ -s "$KEY_FILE" ]] || die "Auth key is missing at $KEY_FILE."
[[ -x "$BASE/Stockfish/src/stockfish" ]] || die 'Stockfish binary is missing; run container.sh first.'
[[ -f "$BASE/engine.env" ]] || die 'Engine configuration is missing; run container.sh first.'

mkdir -p /run/tailscale "$STATE_DIR"
chmod 0755 /run/tailscale

# Reuse a daemon already started with this socket; otherwise start userspace mode.
if ! tailscale --socket="$SOCKET" ip -4 >/dev/null 2>&1; then
  if pgrep -x tailscaled >/dev/null 2>&1; then
    die "A tailscaled process already exists but is not using $SOCKET. Stop the old process before restarting this launcher."
  fi
  TAILSCALED_BIN="$(command -v tailscaled)"
  "$TAILSCALED_BIN" \
    --tun=userspace-networking \
    --state="$STATE_DIR/tailscaled.state" \
    --socket="$SOCKET" \
    --socks5-server=127.0.0.1:1055 \
    --outbound-http-proxy-listen=127.0.0.1:1055 \
    >>"$LOG" 2>&1 &
  TS_PID=$!
else
  TS_PID=""
fi

API_PID=""
cleanup() {
  if [[ -n "${API_PID:-}" ]]; then
    kill "$API_PID" 2>/dev/null || true
    wait "$API_PID" 2>/dev/null || true
  fi
  if [[ -n "${TS_PID:-}" ]]; then
    kill "$TS_PID" 2>/dev/null || true
    wait "$TS_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 60); do
  [[ -S "$SOCKET" ]] && break
  sleep 1
done
[[ -S "$SOCKET" ]] || die "tailscaled did not create its local API socket; inspect $LOG."

if ! tailscale --socket="$SOCKET" ip -4 >/dev/null 2>&1; then
  AUTH_KEY="$(cat "$KEY_FILE")"
  tailscale --socket="$SOCKET" up \
    --auth-key="$AUTH_KEY" \
    --hostname=chesshook-vps \
    --accept-dns=false \
    --ssh=false
  unset AUTH_KEY
fi

TS_IP="$(tailscale --socket="$SOCKET" ip -4 | head -n1)"
[[ -n "$TS_IP" ]] || die 'Tailscale did not assign an IPv4 address.'

# The userspace Tailscale container dataplane forwards incoming tailnet traffic
# on port 8765 to localhost:8765. Keep the API listener loopback-only.
set -a
. "$BASE/engine.env"
set +a
export SF_BIND_HOST=127.0.0.1
export SF_ENGINE="$BASE/Stockfish/src/stockfish"

log "Tailscale userspace mode is online: $TS_IP"
log "API will listen on 127.0.0.1:8765; tailnet clients use http://$TS_IP:8765."
log "Container CPU allocation is controlled by the Podman host; Stockfish threads=$SF_THREADS, Hash=$SF_HASH_MB MiB."

if ! id chesshook >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin chesshook
fi
runuser -u chesshook -- env \
  SF_BIND_HOST=127.0.0.1 \
  SF_ENGINE="$BASE/Stockfish/src/stockfish" \
  SF_THREADS="$SF_THREADS" \
  SF_HASH_MB="$SF_HASH_MB" \
  SF_MAX_MOVETIME_MS=30000 \
  /usr/bin/python3 "$BASE/engine_api.py" &
API_PID=$!
wait "$API_PID"
