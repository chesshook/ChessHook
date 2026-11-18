#!/usr/bin/env bash
# One-time installer for Podman/container hosts without systemd or /dev/net/tun.
set -Eeuo pipefail

log() { printf '\n[chesshook-container-setup] %s\n' "$*"; }
die() { printf '\n[chesshook-container-setup] ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Run this script as root.'
[[ -d /config && -w /config ]] || die 'Expected writable persistent /config volume; cannot store Tailscale identity there.'

BASE=/config/chesshook
mkdir -p "$BASE"
chmod 0700 "$BASE"

# The previous bootstrap saved the key in /etc before stopping at its systemd guard.
# Migrate it into /config so it can survive ordinary container restarts.
KEY_FILE="$BASE/ts-auth-key"
if [[ ! -s "$KEY_FILE" && -s /etc/chesshook/ts-auth-key ]]; then
  install -m 0600 /etc/chesshook/ts-auth-key "$KEY_FILE"
fi
[[ -s "$KEY_FILE" ]] || die "No saved auth key found. Expected $KEY_FILE or /etc/chesshook/ts-auth-key."
chmod 0600 "$KEY_FILE"
AUTH_KEY="$(cat "$KEY_FILE")"
[[ "$AUTH_KEY" == tskey-auth-* ]] || die 'Saved Tailscale auth key has an unexpected format.'
unset AUTH_KEY

OS_ID="$(. /etc/os-release && printf '%s' "${ID:-unknown}")"
[[ "$OS_ID" == ubuntu || "$OS_ID" == debian ]] || die "Ubuntu/Debian required; detected $OS_ID."
NCPU="$(nproc)"
THREADS=$((NCPU * 90 / 100))
((THREADS < 1)) && THREADS=1

export DEBIAN_FRONTEND=noninteractive
log "Installing build/runtime packages; visible CPUs=$NCPU, Stockfish threads=$THREADS."
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git build-essential python3 util-linux procps

if ! command -v tailscaled >/dev/null 2>&1 || ! command -v tailscale >/dev/null 2>&1; then
  log 'Installing Tailscale (userspace mode will be started by container-run.sh).'
  curl -fsSL https://tailscale.com/install.sh | sh
fi
command -v tailscaled >/dev/null 2>&1 || die 'tailscaled binary was not installed.'
command -v tailscale >/dev/null 2>&1 || die 'tailscale CLI was not installed.'

ENGINE_DIR="$BASE/Stockfish"
ENGINE_BIN="$ENGINE_DIR/src/stockfish"
if [[ ! -x "$ENGINE_BIN" ]]; then
  if [[ -d "$ENGINE_DIR/.git" ]]; then
    log 'Updating existing Stockfish checkout to the sf_19 tag.'
    git -C "$ENGINE_DIR" fetch --depth=1 origin tag sf_19
    git -C "$ENGINE_DIR" checkout --force sf_19
  else
    rm -rf "$ENGINE_DIR"
    log 'Fetching official Stockfish 19 source.'
    git clone --depth=1 --branch sf_19 https://github.com/official-stockfish/Stockfish.git "$ENGINE_DIR"
  fi
  log "Compiling Stockfish 19 with ARCH=native and $THREADS jobs."
  make -C "$ENGINE_DIR/src" -j"$THREADS" build ARCH=native
fi
[[ -x "$ENGINE_BIN" ]] || die 'Stockfish build did not produce src/stockfish.'
UCI_CHECK="$(printf 'uci\nisready\nquit\n' | timeout 30 "$ENGINE_BIN" 2>&1 || true)"
grep -q 'uciok' <<<"$UCI_CHECK" || die 'Stockfish UCI handshake failed (uciok missing).'
grep -q 'readyok' <<<"$UCI_CHECK" || die 'Stockfish readiness check failed (readyok missing).'

# Use the cgroup memory ceiling when visible, bounded by MemAvailable.
MEM_BYTES=$(( $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) * 1024 ))
CG2_REL="$(awk -F: '$1 == 0 {print $3; exit}' /proc/self/cgroup 2>/dev/null || true)"
if [[ -n "$CG2_REL" ]]; then
  CG_DIR="/sys/fs/cgroup$CG2_REL"
  while [[ "$CG_DIR" == /sys/fs/cgroup* ]]; do
    if [[ -r "$CG_DIR/memory.max" && -r "$CG_DIR/memory.current" ]]; then
      MAX="$(cat "$CG_DIR/memory.max")"; CUR="$(cat "$CG_DIR/memory.current")"
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
((MEM_MB >= 1024)) || die "Only $MEM_MB MiB effective RAM available; refusing unsafe hash allocation."
MEM_BUDGET_MB=$((MEM_MB * 90 / 100))
HASH_MB=$((MEM_BUDGET_MB * 88 / 100))

log "Calculated effective memory=$MEM_MB MiB; Stockfish Hash=$HASH_MB MiB."
log 'Note: the container host controls the cgroup CPU/memory ceilings; this script cannot install per-service systemd limits here.'

curl -fsSL https://raw.githubusercontent.com/chesshook/ChessHook/main/engine_api.py -o "$BASE/engine_api.py"
curl -fsSL https://raw.githubusercontent.com/chesshook/ChessHook/main/container-run.sh -o "$BASE/container-run.sh"
chmod 0644 "$BASE/engine_api.py"
chmod 0755 "$BASE/container-run.sh"
chmod 0755 "$BASE"
chmod 0755 "$ENGINE_DIR" "$ENGINE_DIR/src" "$ENGINE_BIN"

cat > "$BASE/engine.env" <<ENV
SF_ENGINE=$ENGINE_BIN
SF_THREADS=$THREADS
SF_HASH_MB=$HASH_MB
SF_MAX_MOVETIME_MS=30000
SF_BIND_HOST=127.0.0.1
ENV
chmod 0644 "$BASE/engine.env"

if ! id chesshook >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin chesshook
fi

# Stop a previous supervisor instance cleanly, if it was started from this script.
if [[ -s "$BASE/container-run.pid" ]]; then
  OLD_PID="$(cat "$BASE/container-run.pid")"
  if [[ "$OLD_PID" =~ ^[0-9]+$ ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    kill -TERM "$OLD_PID" 2>/dev/null || true
    for _ in $(seq 1 10); do
      kill -0 "$OLD_PID" 2>/dev/null || break
      sleep 1
    done
  fi
fi

log 'Starting the userspace Tailscale + Stockfish API supervisor.'
nohup "$BASE/container-run.sh" >>"$BASE/container.log" 2>&1 </dev/null &
RUNNER_PID=$!
printf '%s\n' "$RUNNER_PID" > "$BASE/container-run.pid"
chmod 0600 "$BASE/container-run.pid"

HEALTH_OK=0
for _ in $(seq 1 180); do
  if curl -fsS http://127.0.0.1:8765/healthz >/dev/null 2>&1; then HEALTH_OK=1; break; fi
  if ! kill -0 "$RUNNER_PID" 2>/dev/null; then
    tail -n 100 "$BASE/container.log" || true
    die 'Container supervisor exited during startup.'
  fi
  sleep 1
done
((HEALTH_OK == 1)) || { tail -n 100 "$BASE/container.log" || true; die 'Local API health check timed out.'; }

TS_IP="$(tailscale --socket=/run/tailscale/tailscaled.sock ip -4 | head -n1)"
log 'Container deployment is running.'
printf '\nLocal health: http://127.0.0.1:8765/healthz\n'
printf 'Tailnet API:  http://%s:8765/healthz\n' "$TS_IP"
printf 'Analysis:     POST http://%s:8765/v1/analyze\n' "$TS_IP"
printf '\nSaved key:    %s (mode 0600)\n' "$KEY_FILE"
printf 'Supervisor:   %s/container-run.sh\n' "$BASE"
printf 'Logs:         %s/container.log\n' "$BASE"
printf '\nFor automatic startup after container restarts, set the hosting panel startup command to:\n'
printf 'bash %s/container-run.sh\n' "$BASE"
