#!/usr/bin/env bash
# Fast, repeatable ChessHook VPS bootstrap.
# Uses the official Stockfish 19 universal binary (no long source compilation).
set -Eeuo pipefail

REPO_URL="https://github.com/chesshook/ChessHook.git"
REPO_BRANCH="feature/ctf-remote-stockfish-offload"
ROOT="${CHESSHOOK_ROOT:-/config/chesshook}"
CACHE="$ROOT/.cache/chesshook"
ENGINE_BIN="$CACHE/Stockfish/src/stockfish"
TOKEN_FILE="$ROOT/.secrets/api-token"
ENV_FILE="$CACHE/engine.env"
TS_STATE_DIR="$ROOT/.tailscale"
TS_STATE="$TS_STATE_DIR/tailscaled.state"
TS_SOCKET="/var/run/tailscale/tailscaled.sock"

log() { printf '\n[chesshook-vps] %s\n' "$*"; }
die() { printf '\n[chesshook-vps] ERROR: %s\n' "$*" >&2; exit 1; }
[[ "${EUID:-$(id -u)}" -eq 0 ]] || die 'Run this from a root shell.'

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl git python3 procps

# Keep generated files under /config, which is the VPS user's visible data area.
mkdir -p "$(dirname "$ROOT")"
if [[ -d "$ROOT/.git" ]]; then
  log 'Updating existing ChessHook backend checkout.'
  git -C "$ROOT" fetch --depth=1 origin "$REPO_BRANCH"
  git -C "$ROOT" checkout -B "$REPO_BRANCH" FETCH_HEAD
else
  [[ ! -e "$ROOT" ]] || mv "$ROOT" "${ROOT}.backup.$(date +%s)"
  git clone --depth=1 --branch "$REPO_BRANCH" "$REPO_URL" "$ROOT"
fi

mkdir -p "$CACHE/Stockfish/src" "$ROOT/.secrets" "$TS_STATE_DIR"
chmod 0700 "$ROOT/.secrets" "$TS_STATE_DIR"

touch "$ROOT/.gitignore"
grep -qxF '.tailscale/' "$ROOT/.gitignore" || printf '%s\n' '.tailscale/' >> "$ROOT/.gitignore"

# Respect cgroup CPU quota; use available CPUs for runtime Stockfish Threads.
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
# Conservative default for containerized VPS environments. Increase explicitly
# after verifying the provider's real CPU/process limits.
ENGINE_THREADS="${CHESSHOOK_THREADS:-4}"
[[ "$ENGINE_THREADS" =~ ^[0-9]+$ ]] && (( ENGINE_THREADS >= 1 && ENGINE_THREADS <= 512 )) || die 'CHESSHOOK_THREADS must be an integer from 1 to 512.'

# Effective available RAM, constrained by cgroup-v2 memory.max where present.
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
(( MEM_MB >= 2048 )) || die "Only ${MEM_MB} MiB effective available RAM is visible; need at least 2 GiB."
# Start with an 8 GiB hash table by default. Override only after verifying
# the actual provider/container memory behavior: CHESSHOOK_HASH_MB=16384, etc.
HASH_MB="${CHESSHOOK_HASH_MB:-4096}"
[[ "$HASH_MB" =~ ^[0-9]+$ ]] && (( HASH_MB >= 512 && HASH_MB <= 131072 )) || die 'CHESSHOOK_HASH_MB must be 512..131072 MiB.'
(( HASH_MB < MEM_MB / 2 )) || die "Requested Hash ${HASH_MB} MiB is too close to or above half of detected available RAM (${MEM_MB} MiB); lower CHESSHOOK_HASH_MB."

# Download pinned official Stockfish 19 universal binary. It selects the best
# supported x86-64 instruction set at runtime, avoiding risky -march=native
# binaries and the long compiler job that was interrupted in the web terminal.
MACHINE_ARCH="$(uname -m)"
case "$MACHINE_ARCH" in
  x86_64) SF_ARCH="x86-64" ;;
  aarch64|arm64) SF_ARCH="arm64" ;;
  riscv64) SF_ARCH="riscv64" ;;
  *) die "Unsupported VPS architecture: $MACHINE_ARCH" ;;
esac
SF_URL="https://github.com/official-stockfish/Stockfish/releases/download/sf_19/stockfish-linux-${SF_ARCH}-universal.tar.gz"
ENGINE_OK=0
if [[ -x "$ENGINE_BIN" ]]; then
  UCI_ID="$(printf 'uci\nquit\n' | timeout 20 "$ENGINE_BIN" 2>/dev/null | grep -m1 '^id name ' || true)"
  [[ "$UCI_ID" == *'Stockfish 19'* ]] && ENGINE_OK=1
fi
if (( ENGINE_OK == 0 )); then
  log "Downloading official Stockfish 19 universal binary for $MACHINE_ARCH."
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "${TMP_DIR:-}"' EXIT
  curl -fL --retry 3 --connect-timeout 20 "$SF_URL" -o "$TMP_DIR/stockfish.tar.gz"
  tar -xzf "$TMP_DIR/stockfish.tar.gz" -C "$TMP_DIR"
  CANDIDATE="$TMP_DIR/stockfish/stockfish-linux-${SF_ARCH}-universal"
  [[ -x "$CANDIDATE" ]] || CANDIDATE="$(find "$TMP_DIR" -type f -perm /111 -print -quit)"
  [[ -n "$CANDIDATE" && -x "$CANDIDATE" ]] || die 'Could not locate the executable in the official Stockfish archive.'
  UCI_ID="$(printf 'uci\nquit\n' | timeout 20 "$CANDIDATE" 2>/dev/null | grep -m1 '^id name ' || true)"
  [[ "$UCI_ID" == *'Stockfish 19'* ]] || die "Downloaded executable did not identify as Stockfish 19 (reported: $UCI_ID)."
  install -m 0755 "$CANDIDATE" "$ENGINE_BIN"
  rm -rf "$TMP_DIR"
  trap - EXIT
fi
UCI_CHECK="$(printf 'uci\nisready\nquit\n' | timeout 30 "$ENGINE_BIN" 2>&1 || true)"
grep -q '^id name Stockfish 19' <<<"$UCI_CHECK" || die 'Stockfish 19 UCI verification failed.'
grep -q 'uciok' <<<"$UCI_CHECK" || die 'Stockfish UCI handshake failed.'
grep -q 'readyok' <<<"$UCI_CHECK" || die 'Stockfish readiness check failed.'
UCI_ID="$(grep -m1 '^id name ' <<<"$UCI_CHECK")"

# Preflight the exact Threads/Hash settings before launching the long-running API.
# This catches engine crashes during large memory/thread initialization with a
# clear diagnostic, instead of failing inside the HTTP server constructor.
log "Testing Stockfish initialization with Threads=$ENGINE_THREADS and Hash=$HASH_MB MiB."
UCI_RESOURCE_CHECK="$(
  {
    printf 'uci\n'
    sleep 2
    printf 'setoption name NumaPolicy value none\n'
    printf 'setoption name Threads value %s\n' "$ENGINE_THREADS"
    sleep 2
    printf 'setoption name Hash value %s\n' "$HASH_MB"
    sleep 3
    printf 'isready\n'
    sleep 3
    printf 'quit\n'
  } | timeout 120 "$ENGINE_BIN" 2>&1
)" || {
  printf '%s\n' "$UCI_RESOURCE_CHECK" | tail -n 40
  die 'Stockfish exited during Threads/Hash/NUMA preflight. Keep CHESSHOOK_THREADS=4 CHESSHOOK_HASH_MB=4096 and inspect the output above.'
}
grep -q 'readyok' <<<"$UCI_RESOURCE_CHECK" || {
  printf '%s\n' "$UCI_RESOURCE_CHECK" | tail -n 40
  die 'Stockfish did not become ready with the requested resources. Retry with CHESSHOOK_THREADS=4 CHESSHOOK_HASH_MB=4096.'
}

# Preserve API bearer across resets. Reuse an existing client token or generate
# a new one once; it is stored only under /config/chesshook/.secrets.
if [[ ! -s "$TOKEN_FILE" ]]; then
  printf '\nNo saved API token found. Enter the existing ChessHook token to retain app settings,\nor press Enter to generate a new token.\n'
  read -r -s -p 'Existing API bearer token (hidden): ' EXISTING_TOKEN
  printf '\n'
  if [[ -n "$EXISTING_TOKEN" ]]; then
    printf '%s\n' "$EXISTING_TOKEN" > "$TOKEN_FILE"
    unset EXISTING_TOKEN
  else
    python3 -c 'import secrets; print(secrets.token_urlsafe(48))' > "$TOKEN_FILE"
    log 'Generated a new API bearer token.'
  fi
fi
chmod 0600 "$TOKEN_FILE"
printf 'SF_THREADS=%s\nSF_HASH_MB=%s\n' "$ENGINE_THREADS" "$HASH_MB" > "$ENV_FILE"
chmod 0600 "$ENV_FILE"

# Tailscale state is kept under /config so a session/container reset can reuse
# the node identity when /config is persistent.
if ! command -v tailscale >/dev/null 2>&1; then
  log 'Installing Tailscale.'
  curl -fsSL https://tailscale.com/install.sh | sh
fi
mkdir -p /var/run/tailscale
# Use our persistent state file/socket, rather than an ephemeral /var/lib state.
if command -v systemctl >/dev/null 2>&1; then
  systemctl disable --now tailscaled.service >/dev/null 2>&1 || true
fi
pkill -x tailscaled 2>/dev/null || true
if [[ -c /dev/net/tun ]]; then
  TS_MODE=()
else
  TS_MODE=(--tun=userspace-networking)
  log 'No /dev/net/tun found; starting Tailscale in userspace mode.'
fi
nohup tailscaled "${TS_MODE[@]}" --state="$TS_STATE" --socket="$TS_SOCKET" \
  >/var/log/chesshook-tailscaled.log 2>&1 </dev/null &
TS_PID=$!
TS_READY=0
for _ in $(seq 1 30); do
  if [[ -S "$TS_SOCKET" ]] && tailscale --socket="$TS_SOCKET" status --json >/dev/null 2>&1; then
    TS_READY=1
    break
  fi
  kill -0 "$TS_PID" 2>/dev/null || { tail -n 60 /var/log/chesshook-tailscaled.log || true; die 'tailscaled failed to start.'; }
  sleep 1
done
(( TS_READY == 1 )) || die 'Tailscale daemon did not become ready.'
ts() { tailscale --socket="$TS_SOCKET" "$@"; }

TS_RUNNING="$(ts status --json | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))')"
if [[ "$TS_RUNNING" != "Running" ]]; then
  printf '\nTailscale needs authentication. Use a fresh reusable, tag-restricted pre-auth key.\n'
  read -r -s -p 'Tailscale auth key (hidden): ' TS_AUTH_KEY
  printf '\n'
  [[ -n "$TS_AUTH_KEY" ]] || die 'No Tailscale auth key supplied.'
  ts up --auth-key="$TS_AUTH_KEY" --hostname=chesshook-vps
  unset TS_AUTH_KEY
fi

# Start API on loopback and expose only through private Tailscale Serve.
log "Starting ChessHook: $UCI_ID; Threads=$ENGINE_THREADS; Hash=$HASH_MB MiB."
bash "$ROOT/codespace-start.sh"
ts serve --bg http://127.0.0.1:8765

TS_JSON="$(ts status --json)"
HOSTNAME="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("Self",{}).get("DNSName","").rstrip("."))' <<<"$TS_JSON")"
IPV4="$(ts ip -4 2>/dev/null | head -n1 || true)"
TOKEN="$(cat "$TOKEN_FILE")"

printf '\n============================================================\n'
printf 'ChessHook VPS is ready.\n'
printf 'Engine:       %s\nThreads:      %s\nHash:         %s MiB\n' "$UCI_ID" "$ENGINE_THREADS" "$HASH_MB"
printf 'Tailscale IP: %s\n' "$IPV4"
if [[ -n "$HOSTNAME" ]]; then
  printf 'Brain URL:    https://%s\nHealth:       https://%s/healthz\n' "$HOSTNAME" "$HOSTNAME"
fi
printf 'Persistent data: %s\n' "$ROOT"
printf 'API token file:   %s\n' "$TOKEN_FILE"
printf 'If a new token was created, copy it from the file into the Android app.\n'
printf '============================================================\n'
unset TOKEN
