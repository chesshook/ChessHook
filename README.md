# ChessHook Stockfish 19 — Tailscale Codespaces brain

This repository runs a persistent Stockfish 19 UCI engine inside a GitHub Codespace and exposes an authenticated analysis API to the phone over a private Tailscale network. The backend performs chess-position analysis only; board detection, UI, and any local mobile automation remain on the client.

## Brain resources

The supported devcontainer profile is Ubuntu 24.04 with 2 vCPUs and 8 GB RAM. The installer detects the actual CPU quota and effective available memory, then writes fixed \`SF_THREADS\` and \`SF_HASH_MB\` values to the ignored \`.cache/chesshook/engine.env\`. Stockfish hash is limited to at most 65% of effective available memory, rounded down to 256 MiB, with a 4096 MiB cap. The phone's CPU-thread and RAM sliders do not override these server values.

## Provision the Codespace

1. In Tailscale, create a tag-restricted, one-off auth key for the brain device. Avoid reusable keys unless you have a specific managed-key process.
2. In GitHub repository settings, add a **Codespaces** secret named \`TS_AUTH_KEY\` with that new key as its value. Do not put the key in this repository, \`.devcontainer/devcontainer.json\`, or a shell command.
3. Rebuild the Codespace container so the Tailscale devcontainer feature is installed and can read the secret.
4. In the Codespace terminal, run:

   \`\`\`bash
   git pull --ff-only
   bash ./codespace.sh
   \`\`\`

The Tailscale feature starts the daemon and authenticates it using \`TS_AUTH_KEY\`. Its state is persisted for the Codespace. The build script installs dependencies, obtains the official Stockfish 19 \`sf_19\` source, compiles it natively, verifies UCI readiness, generates \`.secrets/api-token\` if absent, and starts the API.

## Private networking

The backend binds only to \`127.0.0.1:8765\`. \`codespace-start.sh\` configures Tailscale Serve to publish that local service over HTTPS to the tailnet:

\`\`\`bash
sudo tailscale serve status
\`\`\`

Copy the \`https://<device>.<tailnet>.ts.net\` origin shown there. In ChessHook, open **Brain Config**, enter that origin and the bearer token from:

\`\`\`bash
cat .secrets/api-token
\`\`\`

Then enable **CTF OFFLOAD**. Keep Codespaces port \`8765\` private/not publicly forwarded, and do not use Tailscale Funnel. Tailscale Serve is tailnet-only and remains subject to tailnet access-control rules; HTTPS certificates must be enabled for the tailnet.

For local diagnostics inside the Codespace:

\`\`\`bash
curl -fsS http://127.0.0.1:8765/healthz
tail -n 100 codespace-api.log
\`\`\`

Restart the API after changing code or server resource configuration:

\`\`\`bash
bash ./codespace-start.sh
\`\`\`

## API and client behavior

The Android client sends FEN, the move history needed to reconstruct the position, and the selected move time. The API streams Stockfish depth/evaluation/PV updates and supports search cancellation, \`ucinewgame\`, and Clear Hash. The server owns all Stockfish threads and hash. The app's time presets, look-ahead/ponder searches, and PV-chain display continue to use the remote results. Syzygy endgame lookups remain on the phone; the app clears the remote Stockfish hash when entering its Syzygy endgame mode.

See [API.md](API.md) for the complete request and response contract.

## Validation

Run the backend API tests with:

\`\`\`bash
python3 -m unittest discover -s tests -v
\`\`\`

The tests use a small fake UCI process and do not download or compile Stockfish.

## Codespaces lifecycle

Codespaces can stop when idle and have a maximum lifetime. The API is unavailable while its Codespace is stopped; it starts again through the devcontainer's \`postStartCommand\`. For an always-on production engine, deploy the same API and Stockfish process on an always-on host in the same tailnet.
