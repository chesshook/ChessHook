# HTTP API

Base URL: `http://TAILSCALE_IP:8765`

The server listens only on the Tailscale IPv4 address configured at install time. It is not intended to be exposed to the public internet.

## Health check

`GET /healthz`

Example response:

```json
{
  "ok": true,
  "engine": "Stockfish 19",
  "threads": 43,
  "hash_mb": 250000
}
```

The values shown for `threads` and `hash_mb` are examples; the service calculates them from the VPS resources at install time.

## Analyze a position

`POST /v1/analyze`

Headers:

`Content-Type: application/json`

Request body:

| Field | Type | Default | Limits / meaning |
|---|---|---:|---|
| `fen` | string | — | Required. Six-field FEN, maximum 128 characters, exactly one king of each color. |
| `movetime_ms` | integer | `2000` | Clamped to 100–30000 milliseconds. |

Example request:

```bash
curl -fsS -X POST 'http://TAILSCALE_IP:8765/v1/analyze' \
  -H 'Content-Type: application/json' \
  -d '{"fen":"rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1","movetime_ms":1000}'
```

Example success response:

```json
{
  "bestmove": "e2e4",
  "ponder": "e7e5",
  "depth": 18,
  "score_cp": 25,
  "score_mate": null,
  "nodes": 1234567,
  "nps": 1200000,
  "pv": ["e2e4", "e7e5", "g1f3"],
  "threads": 43,
  "hash_mb": 250000,
  "movetime_ms": 1000,
  "score_perspective": "side_to_move",
  "elapsed_ms": 1004
}
```

The values above are illustrative; actual engine output depends on the position and VPS performance. `score_cp` is centipawns. When Stockfish reports a mate score, `score_mate` is populated and `score_cp` is null. The principal-variation moves in `pv` are UCI coordinate notation.

## Status codes

| HTTP status | Meaning |
|---|---|
| `200` | Analysis completed. |
| `400` | Invalid JSON, FEN, or request parameter. |
| `404` | Unknown endpoint. |
| `413` | Missing or oversized request body (valid body size: 2–16384 bytes). |
| `429` | Another analysis is already running; retry shortly. |
| `503` | Engine or server-side analysis error. |

Only one search is run at a time because the service owns a single Stockfish process. The API does not provide a game-client integration or make moves in another application.
