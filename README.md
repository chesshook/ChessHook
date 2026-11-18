# ChessHook VPS backend

Stockfish 19 analysis backend for Ubuntu 24.04, including both a full VM deployment and a restricted Podman/container deployment.

This repository contains the **server backend only**. It does not inspect another app's process memory, read a device screen, or automate moves in a client app. Client integration is intentionally separate.

## Choose the deployment mode

### A. Full Ubuntu VPS / VM (systemd + TUN available)

Use [vps.sh](vps.sh). It installs Stockfish 19, starts the normal Tailscale interface, and runs the API under systemd. It calculates 90% of visible CPUs for Stockfish threads and applies a systemd CPU quota. It calculates a memory ceiling from effective available memory and sets the Stockfish hash to 88% of that service budget.

The script stores the Tailscale key in `/etc/chesshook/ts-auth-key` with mode `0600` and reuses it on reruns.

### B. Podman / restricted container (no systemd and/or no /dev/net/tun)

Use [container.sh](container.sh). This is designed for environments like the current restricted container where PID 1 is `podman-init` and `/dev/net/tun` is absent.

The container path:
- Runs Tailscale with `--tun=userspace-networking`; no TUN device or systemd is required
- Migrates an existing key from `/etc/chesshook/ts-auth-key` into the persistent `/config/chesshook/ts-auth-key` path, mode `0600`
- Stores Tailscale identity under `/config/chesshook/tailscale-state`
- Listens for the API on `127.0.0.1:8765`; userspace Tailscale forwards incoming tailnet traffic on port 8765 to localhost
- Configures 90% of visible CPUs as Stockfish threads
- Calculates the Hash allocation from effective available memory, including a visible cgroup v2 limit where available

The container's host controls CPU and memory cgroup ceilings. This container path cannot create a systemd `CPUQuota`, `MemoryHigh`, or `MemoryMax` service limit from inside the restricted container. It therefore does not claim to reserve CPU cores or enforce a separate per-process memory maximum.

Run the setup command in the existing container. It reuses the key already saved by the earlier bootstrap and does not prompt for it:

```bash
sudo bash -c 'curl -fsSL https://raw.githubusercontent.com/chesshook/ChessHook/main/container.sh | bash'
```

For automatic startup after the hosting panel restarts the container, set its startup command to:

```bash
bash /config/chesshook/container-run.sh
```

The container must retain `/config` across restarts for the Tailscale identity, key file, Stockfish build, and scripts to persist. If the host replaces the container without preserving `/config`, these files must be restored and the node may need to authenticate again.

## API

After startup, obtain the container's Tailscale IPv4 address with:

```bash
tailscale --socket=/run/tailscale/tailscaled.sock ip -4
```

- Health: `GET http://TAILSCALE_IP:8765/healthz`
- Analysis: `POST http://TAILSCALE_IP:8765/v1/analyze`

Example:

```bash
curl -fsS -X POST 'http://TAILSCALE_IP:8765/v1/analyze' \
  -H 'Content-Type: application/json' \
  -d '{"fen":"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1","movetime_ms":1000}'
```

See [API.md](API.md) for the request and response contract.

## Container diagnostics

```bash
tail -n 100 /config/chesshook/container.log
tail -n 100 /config/chesshook/tailscaled.log
curl -fsS http://127.0.0.1:8765/healthz
tailscale --socket=/run/tailscale/tailscaled.sock status
```

## VM service operations

```bash
systemctl status chesshook-stockfish --no-pager
journalctl -u chesshook-stockfish -f
systemctl restart chesshook-stockfish
tailscale status
```

The API is reachable over the tailnet only in the intended network configuration. Restrict access using your Tailscale access policy; do not expose TCP port 8765 on a public interface.
