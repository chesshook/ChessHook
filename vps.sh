#!/usr/bin/env bash
# ChessHook VPS bootstrap: Stockfish 19 analysis API, Tailscale-only.
set -Eeuo pipefail

log() { printf '\n[chesshook-vps] %s\n' "$*"; }
die() { printf '\n[chesshook-vps] ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Run this script as root.'

# Reuse a root-only local key file so re-runs do not prompt.
AUTH_KEY_FILE=/etc/chesshook/ts-auth-key
install -d -m 0700 /etc/chesshook
if [[ -z "${TS_AUTH_KEY:-}" && -s "$AUTH_KEY_FILE" ]]; then
  TS_AUTH_KEY="$(cat "$AUTH_KEY_FILE")"
fi
[[ -n "${TS_AUTH_KEY:-}" ]] || die "No Tailscale key found. Set TS_AUTH_KEY once; the script will save it locally with mode 0600."
[[ "$TS_AUTH_KEY" == tskey-auth-* ]] || die 'Unexpected Tailscale auth-key format.'
umask 077
printf '%s\\n' "$TS_AUTH_KEY" > "$AUTH_KEY_FILE"
chmod 0600 "$AUTH_KEY_FILE"

OS_ID="$(. /etc/os-release && printf '%s' "${ID:-unknown}")"
[[ "$OS_ID" == ubuntu || "$OS_ID" == debian ]] || die "Ubuntu/Debian required; detected $OS_ID."

# This bootstrap installs systemd services and requires a real systemd-managed VPS host.
PID1="$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]' || true)"
[[ "$PID1" == "systemd" && -d /run/systemd/system ]] || die "PID 1 is '$PID1', not systemd. This shell is a container/non-systemd environment; run the bootstrap on the Ubuntu VPS host, or provide a TUN-enabled container with a service manager."

NCPU="$(nproc)"
THREADS=$((NCPU * 90 / 100))
((THREADS < 1)) && THREADS=1
CPU_QUOTA=$((THREADS * 100))

export DEBIAN_FRONTEND=noninteractive
log "Installing prerequisites; visible CPUs=$NCPU, Stockfish threads=$THREADS."
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git build-essential python3

if ! command -v tailscale >/dev/null 2>&1; then
  log 'Installing Tailscale.'
  curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl daemon-reload
systemctl enable --now tailscaled
if ! tailscale ip -4 >/dev/null 2>&1; then
  log 'Joining the tailnet.'
  tailscale up --auth-key="$TS_AUTH_KEY" --hostname=chesshook-vps --accept-dns=false --ssh=false
else
  log 'Tailscale is already authenticated; preserving the existing node state.'
fi
unset TS_AUTH_KEY
TS_IP="$(tailscale ip -4 | head -n1)"
[[ -n "$TS_IP" ]] || die 'Tailscale did not return an IPv4 address.'

BASE=/opt/chesshook
ENGINE_DIR="$BASE/Stockfish"
ENGINE_BIN="$ENGINE_DIR/src/stockfish"
install -d -m 0755 "$BASE" /etc/chesshook

if [[ ! -x "$ENGINE_BIN" ]]; then
  log 'Fetching official Stockfish 19 source.'
  if [[ -d "$ENGINE_DIR/.git" ]]; then
    git -C "$ENGINE_DIR" fetch --depth=1 origin tag sf_19
    git -C "$ENGINE_DIR" checkout --force sf_19
  else
    rm -rf "$ENGINE_DIR"
    git clone --depth=1 --branch sf_19 https://github.com/official-stockfish/Stockfish.git "$ENGINE_DIR"
  fi
  log "Compiling Stockfish 19 with ARCH=native and $THREADS build jobs."
  make -C "$ENGINE_DIR/src" -j"$THREADS" build ARCH=native
fi
[[ -x "$ENGINE_BIN" ]] || die 'Stockfish build did not produce src/stockfish.'
UCI_CHECK="$(printf 'uci\nisready\nquit\n' | timeout 30 "$ENGINE_BIN" 2>&1 || true)"
grep -q 'uciok' <<<"$UCI_CHECK" || die 'Stockfish UCI handshake failed (uciok missing).'
grep -q 'readyok' <<<"$UCI_CHECK" || die 'Stockfish readiness check failed (readyok missing).'

# Compute an effective memory budget, respecting host MemAvailable and
# enclosing cgroup limits. The resulting systemd limit is 90% of this value.
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
else
  CG1_REL="$(awk -F: '$2 ~ /(^|,)memory(,|$)/ {print $3; exit}' /proc/self/cgroup 2>/dev/null || true)"
  if [[ -n "$CG1_REL" ]]; then
    CG_DIR="/sys/fs/cgroup/memory$CG1_REL"
    while [[ "$CG_DIR" == /sys/fs/cgroup/memory* ]]; do
      if [[ -r "$CG_DIR/memory.limit_in_bytes" && -r "$CG_DIR/memory.usage_in_bytes" ]]; then
        MAX="$(cat "$CG_DIR/memory.limit_in_bytes")"; CUR="$(cat "$CG_DIR/memory.usage_in_bytes")"
        if [[ "$MAX" =~ ^[0-9]+$ && "$CUR" =~ ^[0-9]+$ ]] && ((MAX < 9223372036854771712)); then
          LEFT=$((MAX > CUR ? MAX - CUR : 0))
          ((LEFT < MEM_BYTES)) && MEM_BYTES="$LEFT"
        fi
      fi
      [[ "$CG_DIR" == /sys/fs/cgroup/memory ]] && break
      CG_DIR="$(dirname "$CG_DIR")"
    done
  fi
fi
MEM_MB=$((MEM_BYTES / 1048576))
((MEM_MB >= 1024)) || die "Only $MEM_MB MiB effective RAM available; refusing unsafe hash allocation."
MEM_LIMIT_MB=$((MEM_MB * 90 / 100))
HASH_MB=$((MEM_LIMIT_MB * 88 / 100))
MEM_HIGH_MB=$((MEM_LIMIT_MB * 95 / 100))
log "Limits: CPUQuota=$CPU_QUOTA%; MemoryMax=$MEM_LIMIT_MB MiB; Stockfish Hash=$HASH_MB MiB."

# Pull the API source from this repository; never place secrets in the repo.
curl -fsSL https://raw.githubusercontent.com/chesshook/ChessHook/main/engine_api.py -o "$BASE/engine_api.py"
chmod 0644 "$BASE/engine_api.py"
cat > /etc/chesshook/engine.env <<ENV
SF_ENGINE=$ENGINE_BIN
SF_THREADS=$THREADS
SF_HASH_MB=$HASH_MB
SF_MAX_MOVETIME_MS=30000
SF_BIND_HOST=$TS_IP
ENV
chmod 0644 /etc/chesshook/engine.env

if ! id chesshook >/dev/null 2>&1; then
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin chesshook
fi
chown -R root:root "$BASE"
chmod 0755 "$BASE" "$ENGINE_DIR" "$ENGINE_DIR/src" "$ENGINE_BIN"

cat > "$BASE/wait-tailnet.sh" <<'WAIT'
#!/bin/sh
set -eu
. /etc/chesshook/engine.env
i=0
while [ "$i" -lt 90 ]; do
  if /usr/bin/tailscale ip -4 | /usr/bin/grep -Fxq "$SF_BIND_HOST"; then exit 0; fi
  i=$((i + 1))
  sleep 1
done
exit 1
WAIT
chmod 0755 "$BASE/wait-tailnet.sh"

cat > /etc/systemd/system/chesshook-stockfish.service <<UNIT
[Unit]
Description=ChessHook Stockfish 19 UCI analysis API
Wants=network-online.target
After=network-online.target tailscaled.service

[Service]
Type=simple
User=chesshook
Group=chesshook
EnvironmentFile=/etc/chesshook/engine.env
WorkingDirectory=$ENGINE_DIR/src
ExecStartPre=+$BASE/wait-tailnet.sh
ExecStart=/usr/bin/python3 $BASE/engine_api.py
Restart=always
RestartSec=3
TimeoutStartSec=240
CPUAccounting=true
CPUQuota=$CPU_QUOTA%
CPUQuotaPeriodSec=100ms
MemoryAccounting=true
MemoryHigh=${MEM_HIGH_MB}M
MemoryMax=${MEM_LIMIT_MB}M
MemorySwapMax=0
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

log 'Starting the systemd service.'
systemctl daemon-reload
systemctl enable chesshook-stockfish.service
systemctl restart chesshook-stockfish.service

log 'Waiting for the API on the Tailscale address.'
HEALTH_OK=0
for _ in $(seq 1 240); do
  if curl -fsS "http://$TS_IP:8765/healthz" >/dev/null 2>&1; then HEALTH_OK=1; break; fi
  if ! systemctl is-active --quiet chesshook-stockfish.service; then
    systemctl --no-pager --full status chesshook-stockfish.service || true
    journalctl -u chesshook-stockfish.service -n 80 --no-pager || true
    die 'Stockfish service exited during startup.'
  fi
  sleep 1
done
((HEALTH_OK == 1)) || { journalctl -u chesshook-stockfish.service -n 80 --no-pager || true; die 'Health check timed out.'; }

log 'Deployment complete; API is bound to the Tailscale IPv4 address only.'
printf '\nHealth:   http://%s:8765/healthz\n' "$TS_IP"
printf 'Analysis: POST http://%s:8765/v1/analyze\n' "$TS_IP"
printf '\nResources: %s/%s CPUs (quota %s%%), MemoryMax %s MiB, Hash %s MiB\n' "$THREADS" "$NCPU" "$CPU_QUOTA" "$MEM_LIMIT_MB" "$HASH_MB"
printf '\nCheck service: systemctl status chesshook-stockfish --no-pager\n'
