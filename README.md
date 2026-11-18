# ChessHook VPS backend

Stockfish 19 analysis backend for an Ubuntu 24.04 VPS. The deployment installs and compiles the official Stockfish 19 source, joins the VPS to your Tailscale network, and runs a small UCI-backed HTTP API under systemd.

This repository contains the **server backend only**. It does not inspect another app's process memory, read a device screen, or automate moves in a client app. Client integration is intentionally separate.

## Target deployment

- Ubuntu 24.04 (the bootstrap also accepts Debian-based systems)
- Stockfish compiled locally with `ARCH=native`
- CPU thread count set to 90% of the vCPUs visible to the VPS
- systemd CPU quota capped at the corresponding percentage
- Service memory ceiling set to 90% of effective available memory at install time
- Stockfish hash set to 88% of that service memory ceiling
- HTTP listener bound only to the VPS's Tailscale IPv4 address on port `8765`
- One analysis search at a time; concurrent analysis requests receive HTTP 429

The CPU quota is a ceiling, not an exclusive reservation of physical cores. The memory ceiling is calculated at installation and does not automatically grow if the host later adds RAM.

## Deploy

Run this on the VPS as a root-capable user. The command prompts for the Tailscale auth key without echoing it, passes it to the installer through the environment, and does not write it to this repository or to the deployment files.

```bash
sudo bash -c 'set -euo pipefail; read -rsp "Tailscale auth key: " TS_AUTH_KEY; printf "\n"; export TS_AUTH_KEY; curl -fsSL https://raw.githubusercontent.com/chesshook/ChessHook/main/vps.sh | bash; unset TS_AUTH_KEY'
```

The Tailscale key must be valid for enrolling this VPS. If the VPS disk is fully reset, its local Tailscale state and installed engine are also lost, so bootstrap must be run again.

## API

After deployment, the installer prints the Tailscale IPv4 address.

- Health: `GET http://TAILSCALE_IP:8765/healthz`
- Analysis: `POST http://TAILSCALE_IP:8765/v1/analyze`

Example:

```bash
curl -fsS -X POST 'http://TAILSCALE_IP:8765/v1/analyze' \
  -H 'Content-Type: application/json' \
  -d '{"fen":"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1","movetime_ms":1000}'
```

See [API.md](API.md) for the request and response contract and [vps.sh](vps.sh) for the complete bootstrap.

## Service operations

```bash
systemctl status chesshook-stockfish --no-pager
journalctl -u chesshook-stockfish -f
systemctl restart chesshook-stockfish
tailscale status
```

The API is plain HTTP inside the Tailscale network. Restrict tailnet access to trusted devices using your Tailscale access policy. Do not expose TCP port 8765 on a public interface.
