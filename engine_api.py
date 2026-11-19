#!/usr/bin/env python3
"""Authenticated, single-engine Stockfish UCI API for ChessHook."""
from __future__ import annotations

import hmac
import json
import os
import queue
import re
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

ENGINE = os.environ.get("SF_ENGINE", "/opt/chesshook/Stockfish/src/stockfish")
THREADS = max(1, int(os.environ.get("SF_THREADS", "1")))
HASH_MB = max(32, int(os.environ.get("SF_HASH_MB", "512")))
MAX_MOVETIME_MS = max(100, min(30000, int(os.environ.get("SF_MAX_MOVETIME_MS", "30000"))))
HOST = os.environ.get("SF_BIND_HOST", "127.0.0.1")
PORT = int(os.environ.get("SF_PORT", "8765"))
API_TOKEN = os.environ.get("CHESSHOOK_API_TOKEN", "")

PIECE_RE = re.compile(r"^[prnbqkPRNBQK1-8]+$")
CASTLE_RE = re.compile(r"^(?:-|K?Q?k?q?)$")
EP_RE = re.compile(r"^(?:-|[a-h][36])$")
UCI_MOVE_RE = re.compile(r"^[a-h][1-8][a-h][1-8][qrbnQRBN]?$")
SEARCH_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,80}$")


def validate_fen(value: object) -> str:
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
    clean_castle = castle.replace("-", "")
    if not CASTLE_RE.fullmatch(castle) or len(clean_castle) != len(set(clean_castle)):
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


def validate_moves(value: object) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or len(value) > 512:
        raise ValueError("moves must be an array containing at most 512 UCI moves")
    moves: list[str] = []
    for move in value:
        if not isinstance(move, str) or not UCI_MOVE_RE.fullmatch(move):
            raise ValueError("moves must contain valid UCI coordinate moves")
        moves.append(move)
    return moves


def parse_info(line: str) -> dict:
    tokens = line.split()
    out: dict = {}
    i = 1
    while i < len(tokens):
        key = tokens[i]
        if key in ("depth", "seldepth", "nodes", "nps", "time") and i + 1 < len(tokens):
            try:
                out[{"seldepth": "seldepth", "time": "time_ms"}.get(key, key)] = int(tokens[i + 1])
            except ValueError:
                pass
            i += 2
        elif key == "score" and i + 2 < len(tokens):
            try:
                if tokens[i + 1] == "cp":
                    out["score_cp"] = int(tokens[i + 2])
                    out.pop("score_mate", None)
                elif tokens[i + 1] == "mate":
                    out["score_mate"] = int(tokens[i + 2])
                    out.pop("score_cp", None)
            except ValueError:
                pass
            i += 3
        elif key in ("lowerbound", "upperbound"):
            out["bound"] = key
            i += 1
        elif key == "pv":
            out["pv"] = tokens[i + 1:i + 31]
            break
        else:
            i += 1
    return out


class UCIEngine:
    def __init__(self) -> None:
        if not os.path.isfile(ENGINE) or not os.access(ENGINE, os.X_OK):
            raise RuntimeError("Stockfish executable is missing or not executable")
        self.proc = subprocess.Popen(
            [ENGINE], cwd=os.path.dirname(ENGINE), stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            bufsize=1, env={**os.environ, "LC_ALL": "C"},
        )
        self.lines: queue.Queue[str] = queue.Queue()
        self.write_lock = threading.Lock()
        self._reader_thread = threading.Thread(
            target=self._reader, daemon=True, name="uci-reader"
        )
        self._reader_thread.start()
        self.send("uci")
        self.wait_for("uciok", 30)
        # Disable automatic NUMA binding. Some containerized VPS environments
        # expose synthetic multi-node topology that makes Stockfish thread
        # initialization fail; this was verified with Stockfish 19 on the VPS.
        self.send("setoption name NumaPolicy value none")
        self.send(f"setoption name Threads value {THREADS}")
        self.send(f"setoption name Hash value {HASH_MB}")
        self.send("setoption name MultiPV value 1")
        self.send("setoption name Ponder value false")
        self.send("isready")
        self.wait_for("readyok", 60)

    def _reader(self) -> None:
        try:
            assert self.proc.stdout is not None
            for line in self.proc.stdout:
                self.lines.put(line.strip())
        finally:
            self.lines.put("__ENGINE_EOF__")

    def send(self, command: str) -> None:
        with self.write_lock:
            if self.proc.poll() is not None:
                raise RuntimeError("Stockfish process exited")
            assert self.proc.stdin is not None
            self.proc.stdin.write(command + "\n")
            self.proc.stdin.flush()

    def wait_for(self, token: str, timeout: float) -> str:
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

    def _position_command(self, fen: str, startpos: bool,
                          anchor_fen: str | None, moves: list[str]) -> str:
        if startpos and moves:
            return "position startpos moves " + " ".join(moves)
        if anchor_fen and moves:
            return "position fen " + anchor_fen + " moves " + " ".join(moves)
        return "position fen " + fen

    def analyze(self, *, fen: str, movetime_ms: int, search_state: dict,
                startpos: bool = False, anchor_fen: str | None = None,
                moves: list[str] | None = None, is_my_turn: bool = True,
                progress=None) -> dict:
        while True:
            try:
                self.lines.get_nowait()
            except queue.Empty:
                break
        self.send(self._position_command(fen, startpos, anchor_fen, moves or []))
        self.send(f"go movetime {movetime_ms}")
        started = time.monotonic()
        deadline = started + movetime_ms / 1000.0 + 5.0
        latest: dict = {}
        stable_move = ""
        stable_depth_count = 0
        last_seen_depth = 0
        last_callback = 0.0
        saw_bestmove = False

        while time.monotonic() < deadline:
            remaining = max(0.01, min(0.12, deadline - time.monotonic()))
            try:
                line = self.lines.get(timeout=remaining)
            except queue.Empty:
                continue
            if line == "__ENGINE_EOF__":
                raise RuntimeError("Stockfish exited during search")
            if line.startswith("info ") and " pv " in line:
                update = parse_info(line)
                if update.get("bound"):
                    continue
                latest.update(update)
                pv = latest.get("pv") or []
                if pv:
                    latest["bestmove"] = pv[0]
                depth = int(latest.get("depth", 0))
                move = str(latest.get("bestmove", ""))
                if depth > last_seen_depth:
                    last_seen_depth = depth
                    if move == stable_move:
                        stable_depth_count += 1
                    else:
                        stable_move = move
                        stable_depth_count = 1
                now = time.monotonic()
                mate = latest.get("score_mate")
                if mate is not None and mate > 0:
                    required_depth = min(16, max(2, abs(int(mate)) * 2 + 2))
                    if depth >= required_depth:
                        self.send("stop")
                elif is_my_turn and movetime_ms <= 950 and depth >= 18 \
                        and stable_depth_count >= 7 \
                        and (now - started) >= movetime_ms / 1000.0 * 0.55:
                    self.send("stop")
                if progress and move and (now - last_callback) >= 0.065:
                    last_callback = now
                    progress(dict(latest))
            elif line.startswith("bestmove "):
                parts = line.split()
                latest["bestmove"] = parts[1] if len(parts) > 1 else "(none)"
                latest["ponder"] = parts[3] if len(parts) > 3 and parts[2] == "ponder" else None
                saw_bestmove = True
                break

        if not saw_bestmove:
            self.send("stop")
            stop_deadline = time.monotonic() + 1.5
            while time.monotonic() < stop_deadline:
                try:
                    line = self.lines.get(timeout=0.05)
                except queue.Empty:
                    continue
                if line.startswith("bestmove "):
                    parts = line.split()
                    latest["bestmove"] = parts[1] if len(parts) > 1 else "(none)"
                    latest["ponder"] = parts[3] if len(parts) > 3 and parts[2] == "ponder" else None
                    saw_bestmove = True
                    break
            if not saw_bestmove:
                raise TimeoutError("Stockfish search exceeded its response deadline")

        elapsed = int((time.monotonic() - started) * 1000)
        latest.setdefault("pv", [])
        if not latest.get("bestmove") and latest["pv"]:
            latest["bestmove"] = latest["pv"][0]
        latest.update({
            "threads": THREADS,
            "hash_mb": HASH_MB,
            "movetime_ms": movetime_ms,
            "elapsed_ms": elapsed,
            "score_perspective": "side_to_move",
            "cancelled": bool(search_state.get("cancelled")),
        })
        return latest

    def stop(self) -> None:
        if self.proc.poll() is None:
            self.send("stop")

    def clear_hash(self) -> None:
        self.send("setoption name Clear Hash")
        self.send("isready")
        self.wait_for("readyok", 15)

    def new_game(self) -> None:
        self.send("ucinewgame")
        self.send("setoption name Clear Hash")
        self.send("isready")
        self.wait_for("readyok", 20)


engine = UCIEngine()
analysis_gate = threading.Lock()
active_lock = threading.Lock()
active_search: dict | None = None


class Handler(BaseHTTPRequestHandler):
    server_version = "ChessHookVPS/2.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print("[http] " + (fmt % args), flush=True)

    def send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        try:
            size = int(self.headers.get("Content-Length", "0"))
        except ValueError as exc:
            raise ValueError("invalid Content-Length") from exc
        if size < 2 or size > 65536:
            raise ValueError("request body must be between 2 and 65536 bytes")
        raw = self.rfile.read(size)
        payload = json.loads(raw)
        if not isinstance(payload, dict):
            raise ValueError("JSON body must be an object")
        return payload

    def _authorized(self) -> bool:
        if not API_TOKEN:
            self.send_json(503, {"error": "API authentication is not configured"})
            return False
        supplied = self.headers.get("Authorization", "")
        if not hmac.compare_digest(supplied, "Bearer " + API_TOKEN):
            self.send_response(401)
            self.send_header("WWW-Authenticate", "Bearer")
            self.send_header("Content-Length", "0")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return False
        return True

    def do_GET(self):
        if urlsplit(self.path).path == "/healthz":
            self.send_json(200, {
                "ok": True, "engine": "Stockfish 19",
                "threads": THREADS, "hash_mb": HASH_MB,
            })
        else:
            self.send_json(404, {"error": "not found"})

    def _parse_analyze(self, payload: dict) -> tuple:
        fen = validate_fen(payload.get("fen"))
        movetime = int(payload.get("movetime_ms", 2000))
        movetime = max(100, min(movetime, MAX_MOVETIME_MS))
        startpos = bool(payload.get("startpos", False))
        anchor = payload.get("anchor_fen")
        anchor_fen = validate_fen(anchor) if isinstance(anchor, str) and anchor else None
        moves = validate_moves(payload.get("moves"))
        if moves and not startpos and not anchor_fen:
            raise ValueError("anchor_fen is required when moves are supplied without startpos")
        is_my_turn = payload.get("is_my_turn", True)
        if not isinstance(is_my_turn, bool):
            raise ValueError("is_my_turn must be boolean")
        # Old synchronous clients did not send a search identifier.
        search_id = payload.get("search_id") or uuid.uuid4().hex
        if not isinstance(search_id, str) or not SEARCH_ID_RE.fullmatch(search_id):
            raise ValueError("search_id must be an 8-80 character request identifier")
        return fen, movetime, startpos, anchor_fen, moves, is_my_turn, search_id

    def _set_active_search(self, search_id: str) -> dict:
        global active_search
        state = {"id": search_id, "cancelled": False}
        with active_lock:
            active_search = state
        return state

    def _clear_active_search(self, state: dict) -> None:
        global active_search
        with active_lock:
            if active_search is state:
                active_search = None

    def do_POST(self):
        path = urlsplit(self.path).path
        if path not in ("/v1/analyze", "/v1/analyze/stream", "/v1/stop", "/v1/newgame", "/v1/clear-hash"):
            self.send_json(404, {"error": "not found"})
            return
        if not self._authorized():
            return
        try:
            payload = self._read_json()
        except (ValueError, TypeError, json.JSONDecodeError) as exc:
            self.send_json(400, {"error": str(exc)})
            return

        if path == "/v1/stop":
            search_id = payload.get("search_id")
            with active_lock:
                state = active_search
                matched = bool(state and isinstance(search_id, str) and state["id"] == search_id)
                if matched:
                    state["cancelled"] = True
            if matched:
                try:
                    engine.stop()
                except Exception as exc:
                    self.send_json(503, {"error": "could not stop active Stockfish search: " + str(exc)})
                    return
            self.send_json(200, {"ok": True, "stopped": bool(matched)})
            return

        if path in ("/v1/newgame", "/v1/clear-hash"):
            if not analysis_gate.acquire(blocking=False):
                self.send_json(429, {"error": "engine is busy; retry after the active search stops"})
                return
            try:
                if path == "/v1/newgame":
                    engine.new_game()
                else:
                    engine.clear_hash()
                self.send_json(200, {"ok": True, "threads": THREADS, "hash_mb": HASH_MB})
            except Exception as exc:
                self.send_json(503, {"error": str(exc)})
            finally:
                analysis_gate.release()
            return

        try:
            fen, movetime, startpos, anchor_fen, moves, is_my_turn, search_id = self._parse_analyze(payload)
        except (ValueError, TypeError) as exc:
            self.send_json(400, {"error": str(exc)})
            return
        if not analysis_gate.acquire(blocking=False):
            self.send_json(429, {"error": "engine is busy; retry shortly"})
            return

        state = self._set_active_search(search_id)
        started = time.monotonic()
        streaming = path == "/v1/analyze/stream"
        connected = True

        def emit_event(kind: str, data: dict) -> bool:
            nonlocal connected
            if not streaming or not connected:
                return connected
            encoded = (json.dumps({"type": kind, "data": data}, separators=(",", ":")) + "\n").encode("utf-8")
            try:
                self.wfile.write((format(len(encoded), "X") + "\r\n").encode("ascii"))
                self.wfile.write(encoded + b"\r\n")
                self.wfile.flush()
                return True
            except (BrokenPipeError, ConnectionResetError, OSError):
                connected = False
                return False

        if streaming:
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson; charset=utf-8")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()

        try:
            result = engine.analyze(
                fen=fen, movetime_ms=movetime, search_state=state,
                startpos=startpos, anchor_fen=anchor_fen, moves=moves,
                is_my_turn=is_my_turn,
                progress=lambda update: emit_event("info", update),
            )
            result["elapsed_ms"] = int((time.monotonic() - started) * 1000)
            if streaming:
                emit_event("result", result)
                if connected:
                    self.wfile.write(b"0\r\n\r\n")
                    self.wfile.flush()
            else:
                self.send_json(200, result)
        except Exception as exc:
            if streaming:
                emit_event("error", {"message": str(exc)})
                if connected:
                    try:
                        self.wfile.write(b"0\r\n\r\n")
                        self.wfile.flush()
                    except OSError:
                        pass
            else:
                self.send_json(503, {"error": str(exc)})
        finally:
            self._clear_active_search(state)
            analysis_gate.release()
            self.close_connection = True


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


if __name__ == "__main__":
    print(f"ChessHook Stockfish API listening on {HOST}:{PORT}; "
          f"threads={THREADS}; hash={HASH_MB} MiB", flush=True)
    Server((HOST, PORT), Handler).serve_forever()
