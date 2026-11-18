#!/usr/bin/env python3
"""Deterministic fake UCI engine for API integration tests."""
import select
import sys
import time

for raw in sys.stdin:
    cmd = raw.strip()
    if cmd == "uci":
        print("id name FakeStockfish", flush=True)
        print("uciok", flush=True)
    elif cmd == "isready":
        print("readyok", flush=True)
    elif cmd.startswith("go movetime "):
        try:
            ms = int(cmd.rsplit(" ", 1)[1])
        except Exception:
            ms = 250
        print("info depth 12 seldepth 16 score cp 34 nodes 12345 nps 98765 time 35 pv e2e4 e7e5 g1f3 b8c6", flush=True)
        deadline = time.monotonic() + max(0.25, ms / 1000.0)
        while time.monotonic() < deadline:
            ready, _, _ = select.select([sys.stdin], [], [], 0.02)
            if ready:
                nxt = sys.stdin.readline()
                if not nxt:
                    break
                nxt = nxt.strip()
                if nxt == "stop":
                    break
                if nxt == "isready":
                    print("readyok", flush=True)
                if nxt == "quit":
                    sys.exit(0)
        print("bestmove e2e4 ponder e7e5", flush=True)
    elif cmd == "quit":
        break
