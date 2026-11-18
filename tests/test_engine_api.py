"""End-to-end smoke tests for the authenticated Stockfish HTTP API."""
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import unittest

ROOT = Path(__file__).resolve().parents[1]
TOKEN = "test-token-for-chesshook-remote-backend-1234567890"
FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class EngineApiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.port = free_port()
        env = os.environ.copy()
        fake_engine = ROOT / "tests" / "fake_stockfish.py"
        fake_engine.chmod(fake_engine.stat().st_mode | 0o111)
        env.update({
            "SF_ENGINE": str(fake_engine),
            "SF_THREADS": "2",
            "SF_HASH_MB": "3328",
            "SF_MAX_MOVETIME_MS": "30000",
            "SF_BIND_HOST": "127.0.0.1",
            "SF_PORT": str(cls.port),
            "CHESSHOOK_API_TOKEN": TOKEN,
            "PYTHONUNBUFFERED": "1",
        })
        cls.server = subprocess.Popen(
            [sys.executable, str(ROOT / "engine_api.py")],
            cwd=ROOT, env=env, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, text=True,
        )
        cls.base = f"http://127.0.0.1:{cls.port}"
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if cls.server.poll() is not None:
                output = cls.server.stdout.read() if cls.server.stdout else ""
                raise RuntimeError(f"API exited during startup:\n{output}")
            try:
                with urllib.request.urlopen(cls.base + "/healthz", timeout=0.2) as response:
                    health = json.loads(response.read())
                if health.get("ok"):
                    break
            except Exception:
                time.sleep(0.05)
        else:
            raise RuntimeError("API health check did not become ready")

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        try:
            cls.server.wait(timeout=3)
        except subprocess.TimeoutExpired:
            cls.server.kill()
            cls.server.wait(timeout=3)
        if cls.server.stdout:
            cls.server.stdout.close()

    def post(self, path, payload, token=TOKEN):
        body = json.dumps(payload).encode()
        req = urllib.request.Request(
            self.base + path, data=body, method="POST",
            headers={"Authorization": "Bearer " + token,
                     "Content-Type": "application/json"},
        )
        return urllib.request.urlopen(req, timeout=8)

    def test_health_reports_server_owned_resources(self):
        with urllib.request.urlopen(self.base + "/healthz", timeout=2) as response:
            body = json.loads(response.read())
        self.assertTrue(body["ok"])
        self.assertEqual(body["threads"], 2)
        self.assertEqual(body["hash_mb"], 3328)

    def test_all_control_and_analysis_endpoints_require_bearer_token(self):
        for path, payload in (
            ("/v1/clear-hash", {}), ("/v1/newgame", {}),
            ("/v1/stop", {"search_id": "unauthorized-123"}),
            ("/v1/analyze", {"fen": FEN}),
        ):
            with self.subTest(path=path):
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    self.post(path, payload, token="wrong-token")
                self.assertEqual(caught.exception.code, 401)

    def test_invalid_fen_is_rejected(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.post("/v1/analyze/stream", {"fen": "invalid", "search_id": "invalid-fen-123"})
        self.assertEqual(caught.exception.code, 400)

    def test_legacy_json_analysis_uses_backend_resources(self):
        with self.post("/v1/analyze", {
            "fen": FEN, "movetime_ms": 180,
            "threads": 8, "hash_mb": 32,
        }) as response:
            result = json.loads(response.read())
        self.assertEqual(result["bestmove"], "e2e4")
        self.assertEqual(result["pv"][0], "e2e4")
        self.assertEqual(result["threads"], 2)
        self.assertEqual(result["hash_mb"], 3328)

    def test_streaming_returns_progress_pv_and_final_result(self):
        with self.post("/v1/analyze/stream", {
            "fen": FEN, "movetime_ms": 350,
            "search_id": "stream-analysis-123",
        }) as response:
            events = [json.loads(line) for line in response.read().decode().splitlines() if line]
        self.assertTrue(any(event["type"] == "info" for event in events))
        self.assertEqual(events[-1]["type"], "result")
        self.assertEqual(events[-1]["data"]["bestmove"], "e2e4")
        self.assertGreaterEqual(len(events[-1]["data"]["pv"]), 3)

    def test_active_search_can_be_cancelled(self):
        received = {}

        def run_search():
            connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=8)
            body = json.dumps({
                "fen": FEN, "movetime_ms": 4000,
                "search_id": "cancel-search-123",
            }).encode()
            connection.request("POST", "/v1/analyze/stream", body, {
                "Authorization": "Bearer " + TOKEN,
                "Content-Type": "application/json",
            })
            response = connection.getresponse()
            received["status"] = response.status
            received["first"] = response.readline().decode().strip()
            received["rest"] = response.read().decode()
            connection.close()

        worker = threading.Thread(target=run_search)
        worker.start()
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline and not received.get("first"):
            time.sleep(0.02)
        self.assertTrue(received.get("first"), "stream emitted no progress event")
        with self.post("/v1/stop", {"search_id": "cancel-search-123"}) as response:
            self.assertTrue(json.loads(response.read())["stopped"])
        worker.join(timeout=5)
        self.assertFalse(worker.is_alive(), "cancelled search did not terminate")
        events = [json.loads(line) for line in received["rest"].splitlines() if line]
        self.assertEqual(events[-1]["type"], "result")
        self.assertTrue(events[-1]["data"]["cancelled"])

    def test_remote_clear_hash_and_new_game_controls(self):
        for path in ("/v1/clear-hash", "/v1/newgame"):
            with self.subTest(path=path):
                with self.post(path, {}) as response:
                    result = json.loads(response.read())
                self.assertTrue(result["ok"])
                self.assertEqual(result["threads"], 2)
                self.assertEqual(result["hash_mb"], 3328)


if __name__ == "__main__":
    unittest.main(verbosity=2)
