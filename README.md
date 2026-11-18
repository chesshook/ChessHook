# ChessHook Stockfish 19 — GitHub Codespaces backend

This repository's deployment target is **GitHub Codespaces**. The supported Codespace profile is Ubuntu 24.04 with at least 2 vCPUs and 8 GB RAM.

The backend provides FEN-in / UCI best-move-out chess analysis using the official Stockfish 19 source. It is an analysis API only; it does not inspect another app's process memory, read a device screen, or automate moves in a client app.

## Hardware profile

The supplied Codespace reports 2 vCPUs and approximately 8 GiB RAM. The installer:
- Builds Stockfish 19 with `ARCH=native` using the CPU quota detected inside the Codespace (normally 2 build jobs and 2 engine threads)
- Calculates currently available memory using `MemAvailable` and any visible cgroup v2 memory limit
- Assigns at most 65% of that effective available memory to the Stockfish transposition hash, rounded down to a 256 MiB step and capped at 4096 MiB
- Runs a single analysis search at a time, with requests capped at 30 seconds

This is not the previous 48-vCPU / 330-GB configuration. Codespaces does not expose that hardware to this workspace.

## Install and start

From the repository root inside the Codespace, run:

```bash
git pull --ff-only
bash ./codespace.sh
```

The installer installs build tools, clones the official Stockfish 19 `sf_19` tag into the ignored `.cache/chesshook/` directory, compiles it, verifies the UCI handshake, generates a strong random API token, and starts the HTTP service.

The API token is stored in `.secrets/api-token` with mode `0600`. The `.secrets/` and `.cache/` directories are git-ignored. Do not remove the token file unless you intend to rotate the API credential.

The devcontainer configuration requests the 2-vCPU / 8-GB Ubuntu profile, forwards port 8765, builds the backend after creation, and starts the API when the Codespace starts. These lifecycle settings apply to newly created or rebuilt Codespaces. In the already-running Codespace, run the commands above once; you can also start the already-built API with:

```bash
bash ./codespace-start.sh
```

## Port access

Port `8765` is forwarded automatically and is private by default. Use the forwarded HTTPS URL from the Codespaces **PORTS** panel.

- Browser / GitHub-authenticated access: keep the port **Private**
- External REST clients to a private forwarded port also need the current Codespaces `GITHUB_TOKEN` in an `X-Github-Token` header. That token changes when the Codespace is stopped and restarted.
- For a phone app that cannot provide the rotating GitHub header, change port 8765 to **Public** in the PORTS panel. Public means anyone who knows the URL can reach it, so keep the ChessHook bearer token secret. Analysis requests still require `Authorization: Bearer YOUR_CHESSHOOK_API_TOKEN`.

Do not commit `.secrets/api-token`, copy it into source code, or put it in a public issue.

## API

- Health check: `GET /healthz`
- Analysis: `POST /v1/analyze`

See [API.md](API.md) for the exact request / response format and authentication requirements.

Example local test from the Codespace:

```bash
TOKEN="$(cat .secrets/api-token)"
curl -fsS http://127.0.0.1:8765/healthz
curl -fsS -X POST http://127.0.0.1:8765/v1/analyze \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"fen":"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1","movetime_ms":1000}'
```

## Logs and process control

```bash
tail -n 100 codespace-api.log
cat .secrets/api-token
kill "$(cat codespace-api.pid)"
bash ./codespace-start.sh
```

## Codespaces lifecycle limitation

A Codespace is a development environment, not a continuously available VPS. By default, an inactive Codespace stops after 30 minutes, and a Codespace has a 12-hour maximum lifetime. When it stops, the API process also stops; it restarts when the Codespace starts again through the devcontainer lifecycle hook. The workspace and ignored token file normally persist across a stop/start, but a deleted/recreated Codespace is a new environment and needs setup again.

GitHub's lifecycle documentation: [Codespace lifecycle](https://docs.github.com/en/codespaces/about-codespaces/understanding-the-codespace-lifecycle) · [Port forwarding](https://docs.github.com/en/codespaces/developing-in-a-codespace/forwarding-ports-in-your-codespace).
