#!/usr/bin/env python3
"""Single-search HTTP API for a local Stockfish UCI process."""
import json
import os
import hmac
import queue
import re
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

ENGINE = os.environ.get("SF_ENGINE", "/opt/chesshook/Stockfish/src/stockfish")
THREADS = max(1, int(os.environ.get("SF_THREADS", "1")))
HASH_MB = max(256, int(os.environ.get("SF_HASH_MB", "512")))
MAX_MOVETIME_MS = max(100, int(os.environ.get("SF_MAX_MOVETIME_MS", "30000")))
HOST = os.environ.get("SF_BIND_HOST", "0.0.0.0")
API_TOKEN = os.environ.get("CHESSHOOK_API_TOKEN", "")
PORT = 8765

PIECE_RE = re.compile(r"^[prnbqkPRNBQK1-8]+$")
CASTLE_RE = re.compile(r"^(?:-|K?Q?k?q?)$")
EP_RE = re.compile(r"^(?:-|[a-h][36])$")


def validate_fen(value):
    if not isinstance(value, str) or len(value) > 128:
        raise ValueError("fen must be a string of at most 128 characters")
    fields = value.strip().split()
    if len(fields) != 6:
        raise ValueError("FEN must contain exactly six fields")
    board, turn, castle, ep, halfmove, fullmove = fields
    ranks = board.split("/")
    if len(ranks) != 8:
        raise ValueError("FEN board must have eight ranks")
    wk = bk = 0
    for rank in ranks:
        if not PIECE_RE.fullmatch(rank):
            raise ValueError("FEN board contains an invalid piece or rank character")
        files = 0
        for ch in rank:
            if ch in "12345678":
                files += int(ch)
            else:
                files += 1
                wk += ch == "K"
                bk += ch == "k"
        if files != 8:
            raise ValueError("Each FEN rank must describe exactly eight files")
    if wk != 1 or bk != 1:
        raise ValueError("FEN must contain exactly one king per side")
    if turn not in ("w", "b"):
        raise ValueError("FEN active color must be w or b")
    if not CASTLE_RE.fullmatch(castle) or len(castle.replace("-", "")) != len(set(castle.replace("-", ""))):
        raise ValueError("FEN castling field is invalid")
    if not EP_RE.fullmatch(ep):
        raise ValueError("FEN en-passant field is invalid")
    try:
        hm, fm = int(halfmove), int(fullmove)
    except ValueError as exc:
        raise ValueError("FEN move counters must be integers") from exc
    if hm < 0 or fm < 1:
        raise ValueError("FEN move counters are out of range")
    return " ".join(fields)


class UCIEngine:
    def __init__(self):
        if not os.path.isfile(ENGINE) or not os.access(ENGINE, os.X_OK):
            raise RuntimeError("Stockfish executable is missing or not executable")
        self.proc = subprocess.Popen(
            [ENGINE], cwd=os.path.dirname(ENGINE), stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            bufsize=1, env={**os.environ, "LC_ALL": "C"},
        )
        self.lines = queue.Queue()
        threading.Thread(target=self._reader, daemon=True, name="uci-reader").start()
        self.send("uci")
        self.wait_for("uciok", 30)
        self.send(f"setoption name Threads value {THREADS}")
        self.send(f"setoption name Hash value {HASH_MB}")
        self.send("setoption name MultiPV value 1")
        self.send("setoption name Ponder value false")
        self.send("isready")
        self.wait_for("readyok", 60)

    def _reader(self):
        try:
            for line in self.proc.stdout:
                self.lines.put(line.strip())
        finally:
            self.lines.put("__ENGINE_EOF__")

    def send(self, command):
        if self.proc.poll() is not None:
            raise RuntimeError("Stockfish process exited")
        self.proc.stdin.write(command + "\n")
        self.proc.stdin.flush()

    def wait_for(self, token, timeout):
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"Timed out waiting for Stockfish {token}")
            try:
                line = self.lines.get(timeout=remaining)
            except queue.Empty as exc:
                raise TimeoutError(f"Timed out waiting for Stockfish {token}") from exc
            if line == "__ENGINE_EOF__":
                raise RuntimeError("Stockfish closed its output stream")
            if token in line:
                return line

    def analyze(self, fen, movetime_ms):
        self.send("position fen " + fen)
        self.send(f"go movetime {movetime_ms}")
        deadline = time.monotonic() + movetime_ms / 1000 + 20
        info = {}
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Stockfish search exceeded its response deadline")
            try:
                line = self.lines.get(timeout=remaining)
            except queue.Empty as exc:
                raise TimeoutError("Stockfish search exceeded its response deadline") from exc
            if line == "__ENGINE_EOF__":
                raise RuntimeError("Stockfish exited during search")
            if line.startswith("info "):
                self._parse_info(line, info)
            elif line.startswith("bestmove "):
                parts = line.split()
                return {
                    "bestmove": parts[1] if len(parts) > 1 else "(none)",
                    "ponder": parts[3] if len(parts) > 3 and parts[2] == "ponder" else None,
                    "depth": info.get("depth"),
                    "score_cp": info.get("score_cp"),
                    "score_mate": info.get("score_mate"),
                    "nodes": info.get("nodes"),
                    "nps": info.get("nps"),
                    "pv": info.get("pv", []),
                    "threads": THREADS,
                    "hash_mb": HASH_MB,
                    "movetime_ms": movetime_ms,
                    "score_perspective": "side_to_move",
                }

    @staticmethod
    def _parse_info(line, target):
        tokens = line.split()
        i = 1
        while i < len(tokens):
            key = tokens[i]
            if key in ("depth", "seldepth", "nodes", "nps", "time") and i + 1 < len(tokens):
                try:
                    target[key] = int(tokens[i + 1])
                except ValueError:
                    pass
                i += 2
            elif key == "score" and i + 2 < len(tokens):
                try:
                    if tokens[i + 1] == "cp":
                        target["score_cp"] = int(tokens[i + 2])
                        target.pop("score_mate", None)
                    elif tokens[i + 1] == "mate":
                        target["score_mate"] = int(tokens[i + 2])
                        target.pop("score_cp", None)
                except ValueError:
                    pass
                i += 3
            elif key == "pv":
                target["pv"] = tokens[i + 1:i + 31]
                break
            else:
                i += 1


engine = UCIEngine()
analysis_gate = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    server_version = "ChessHookVPS/1.0"

    def log_message(self, fmt, *args):
        print("[http] " + (fmt % args), flush=True)

    def send_json(self, status, payload):
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if urlsplit(self.path).path == "/healthz":
            self.send_json(200, {
                "ok": True, "engine": "Stockfish 19",
                "threads": THREADS, "hash_mb": HASH_MB,
            })
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if urlsplit(self.path).path != "/v1/analyze":
            self.send_json(404, {"error": "not found"})
            return
        if not API_TOKEN:
            self.send_json(503, {"error": "API authentication is not configured"})
            return
        supplied = self.headers.get("Authorization", "")
        expected = "Bearer " + API_TOKEN
        if not hmac.compare_digest(supplied, expected):
            self.send_response(401)
            self.send_header("WWW-Authenticate", "Bearer")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if not analysis_gate.acquire(blocking=False):
            self.send_json(429, {"error": "engine is busy; retry shortly"})
            return
        try:
            try:
                size = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                size = 0
            if size < 2 or size > 16384:
                self.send_json(413, {"error": "request body must be between 2 and 16384 bytes"})
                return
            try:
                payload = json.loads(self.rfile.read(size))
                if not isinstance(payload, dict):
                    raise ValueError("JSON body must be an object")
                fen = validate_fen(payload.get("fen"))
                requested = int(payload.get("movetime_ms", 2000))
                movetime = max(100, min(requested, MAX_MOVETIME_MS))
            except (ValueError, TypeError, json.JSONDecodeError) as exc:
                self.send_json(400, {"error": str(exc)})
                return
            started = time.monotonic()
            result = engine.analyze(fen, movetime)
            result["elapsed_ms"] = int((time.monotonic() - started) * 1000)
            self.send_json(200, result)
        except Exception as exc:
            self.send_json(503, {"error": str(exc)})
        finally:
            analysis_gate.release()


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    print(f"ChessHook Stockfish API listening on {HOST}:{PORT}; "
          f"threads={THREADS}; hash={HASH_MB} MiB", flush=True)
    Server((HOST, PORT), Handler).serve_forever()
