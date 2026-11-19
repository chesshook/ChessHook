#!/usr/bin/env bash
# ChessHook VPS bootstrap: install/build Stockfish 19, start authenticated API,
# and expose it only through private Tailscale Serve.
set -Eeuo pipefail

REPO_URL="https://github.com/chesshook/ChessHook.git"
REPO_BRANCH="feature/ctf-remote-stockfish-offload"
ROOT="/opt/chesshook"
CACHE="$ROOT/.cache/chesshook"
ENGINE_DIR="$CACHE/Stockfish"
ENGINE_BIN="$ENGINE_DIR/src/stockfish"
TOKEN_FILE="$ROOT/.secrets/api-token"
ENV_FILE="$CACHE/engine.env"

log() { printf '\n[chesshook-vps] %s\n' "$*"; }
die() { printf '\n[chesshook-vps] ERROR: %s\n' "$*" >&2; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die 'Run this from a root shell.'

export DEBIAN_FRONTEND=noninteractive
log 'Installing required build/runtime packages.'
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl git build-essential python3 procps

# Clone/update the backend branch.
if [[ -d "$ROOT/.git" ]]; then
  git -C "$ROOT" fetch --depth=1 origin "$REPO_BRANCH"
  git -C "$ROOT" checkout -B "$REPO_BRANCH" FETCH_HEAD
else
  mkdir -p "$(dirname "$ROOT")"
  if [[ -e "$ROOT" ]]; then
    mv "$ROOT" "${ROOT}.backup.$(date +%s)"
  fi
  git clone --depth=1 --branch "$REPO_BRANCH" "$REPO_URL" "$ROOT"
fi

# Respect cgroup CPU quota, then use all CPUs visible to the container.
CPU_COUNT="$(nproc)"
if [[ -r /sys/fs/cgroup/cpu.max ]]; then
  read -r CPU_QUOTA CPU_PERIOD < /sys/fs/cgroup/cpu.max
  if [[ "$CPU_QUOTA" =~ ^[0-9]+$ && "$CPU_PERIOD" =~ ^[0-9]+$ && "$CPU_PERIOD" -gt 0 ]]; then
    QUOTA_CPUS=$(((CPU_QUOTA + CPU_PERIOD - 1) / CPU_PERIOD))
    (( QUOTA_CPUS < 1 )) && QUOTA_CPUS=1
    (( QUOTA_CPUS < CPU_COUNT )) && CPU_COUNT="$QUOTA_CPUS"
  fi
fi
(( CPU_COUNT > 64 )) && CPU_COUNT=64
(( CPU_COUNT < 1 )) && CPU_COUNT=1

# Calculate effective free RAM, respecting cgroup-v2 limits on parent cgroups.
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
        (( LEFT < MEM_BYTES )) && MEM_BYTES="$LEFT"
      fi
    fi
    [[ "$CG_DIR" == /sys/fs/cgroup ]] && break
    CG_DIR="$(dirname "$CG_DIR")"
  done
fi
MEM_MB=$((MEM_BYTES / 1048576))
(( MEM_MB >= 3072 )) || die "Only ${MEM_MB} MiB effective free RAM is visible; need at least 3 GiB."
HASH_MB=$(( MEM_MB * 65 / 100 ))
HASH_MB=$(( HASH_MB / 1024 * 1024 ))
(( HASH_MB < 1024 )) && HASH_MB=1024
(( HASH_MB > 65536 )) && HASH_MB=65536

mkdir -p "$CACHE" "$ROOT/.secrets"

# Build official Stockfish 19. Verify the executable identity, not just its path.
ENGINE_OK=0
if [[ -x "$ENGINE_BIN" ]]; then
  UCI_ID="$(printf 'uci\nquit\n' | timeout 20 "$ENGINE_BIN" 2>/dev/null | grep -m1 '^id name ' || true)"
  [[ "$UCI_ID" == *'Stockfish 19'* ]] && ENGINE_OK=1
fi
if (( ENGINE_OK == 0 )); then
  rm -rf "$ENGINE_DIR"
  log 'Fetching official Stockfish tag sf_19 and compiling a native binary.'
  git clone --depth=1 --branch sf_19 https://github.com/official-stockfish/Stockfish.git "$ENGINE_DIR"
  make -C "$ENGINE_DIR/src" -j"$CPU_COUNT" build ARCH=native
fi
UCI_CHECK="$(printf 'uci\nisready\nquit\n' | timeout 30 "$ENGINE_BIN" 2>&1 || true)"
grep -q 'id name Stockfish 19' <<<"$UCI_CHECK" || die 'The binary did not identify itself as Stockfish 19.'
grep -q 'uciok' <<<"$UCI_CHECK" || die 'Stockfish UCI handshake failed.'
grep -q 'readyok' <<<"$UCI_CHECK" || die 'Stockfish readiness check failed.'
UCI_ID="$(grep -m1 '^id name ' <<<"$UCI_CHECK")"

# Preserve token on persistent disks. If this VPS loses its disk, re-enter the
# saved app token at the prompt to keep the Android configuration unchanged.
TOKEN_CREATED=0
if [[ ! -s "$TOKEN_FILE" ]]; then
  printf '\nNo saved ChessHook API token was found.\n'
  read -r -s -p 'Existing API bearer token (press Enter to generate a new one): ' EXISTING_TOKEN
  printf '\n'
  if [[ -n "$EXISTING_TOKEN" ]]; then
    printf '%s\n' "$EXISTING_TOKEN" > "$TOKEN_FILE"
    unset EXISTING_TOKEN
  else
    python3 -c 'import secrets; print(secrets.token_urlsafe(48))' > "$TOKEN_FILE"
    TOKEN_CREATED=1
    log 'Generated a new API bearer token. It will be displayed once at the end.'
  fi
  chmod 0600 "$TOKEN_FILE"
fi
chmod 0700 "$ROOT/.secrets"
chmod 0600 "$TOKEN_FILE"
printf 'SF_THREADS=%s\nSF_HASH_MB=%s\n' "$CPU_COUNT" "$HASH_MB" > "$ENV_FILE"
chmod 0600 "$ENV_FILE"

# Install Tailscale if absent.
if ! command -v tailscale >/dev/null 2>&1; then
  log 'Installing Tailscale using its official Linux installer.'
  curl -fsSL https://tailscale.com/install.sh | sh
fi

mkdir -p /var/lib/tailscale /var/run/tailscale
if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
  systemctl enable --now tailscaled || true
fi
if ! pgrep -x tailscaled >/dev/null 2>&1; then
  if [[ -c /dev/net/tun ]]; then
    TS_MODE=()
  else
    TS_MODE=(--tun=userspace-networking)
    log 'No /dev/net/tun detected; using Tailscale userspace networking.'
  fi
  nohup tailscaled "${TS_MODE[@]}" --state=/var/lib/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock \
    >/var/log/tailscaled.log 2>&1 </dev/null &
fi

TS_READY=0
for _ in $(seq 1 30); do
  if tailscale status --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("BackendState")=="Running" else 1)' 2>/dev/null; then
    TS_READY=1
    break
  fi
  sleep 1
done

if (( TS_READY == 0 )); then
  printf '\nTailscale needs authentication. Create a pre-auth key in your Tailscale admin console.\n'
  printf 'Paste it here (input hidden); it is not saved in this repository.\n'
  read -r -s -p 'Tailscale auth key: ' TS_AUTH_KEY
  printf '\n'
  [[ -n "$TS_AUTH_KEY" ]] || die 'No Tailscale auth key entered.'
  tailscale up --auth-key="$TS_AUTH_KEY" --hostname=chesshook-vps
  unset TS_AUTH_KEY
fi

# Start the API; the existing launcher binds it to loopback only.
log "Starting ChessHook API: Stockfish 19, ${CPU_COUNT} thread(s), Hash=${HASH_MB} MiB."
bash "$ROOT/codespace-start.sh"

# Expose only through private Tailscale HTTPS Serve.
tailscale serve --bg http://127.0.0.1:8765

HOSTNAME="$(tailscale status --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("Self",{}).get("DNSName", "").rstrip("."))')"
IPV4="$(tailscale ip -4 2>/dev/null | head -n1 || true)"
TOKEN="$(cat "$TOKEN_FILE")"

printf '\n============================================================\n'
printf 'ChessHook VPS is ready.\n'
printf 'Engine:       %s\n' "$UCI_ID"
printf 'Threads:      %s\n' "$CPU_COUNT"
printf 'Hash:         %s MiB\n' "$HASH_MB"
printf 'Tailscale IP: %s\n' "$IPV4"
if [[ -n "$HOSTNAME" ]]; then
  printf 'Brain URL:    https://%s\n' "$HOSTNAME"
  printf 'Health:       https://%s/healthz\n' "$HOSTNAME"
fi
if (( TOKEN_CREATED == 1 )); then
  printf 'NEW API token: %s\n' "$TOKEN"
  printf 'Copy it into ChessHook > Brain Config and save it securely.\n'
else
  printf 'API token:    reused from the saved token file (not printed).\n'
fi
printf 'To rerun after a reset, execute the same bootstrap command again.\n'
printf '============================================================\n'
