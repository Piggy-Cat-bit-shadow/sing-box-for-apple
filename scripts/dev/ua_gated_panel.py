"""A mock subscription panel for the client's two opt-in transport tests.

Two behaviours are reproduced, and one of them is the reason this file is committed
rather than kept locally.

1. A panel that gates `subscription-userinfo` on the User-Agent. satelite-one's own
   source documents why it masquerades as a Clash client:
       "UA masquerades as clash-verge so panels return the subscription-userinfo header."
       -- satelite-one, SubscriptionFetcher.kt:13
   `GET /sub` answers that way, so a test can show that the client's own identity is
   denied the header while the Clash-compatible metadata probe is granted it.

2. A panel whose body is large and slow, so a probe that only wants the headers can be
   shown not to transfer the body. `GET /big` advertises a large `Content-Length` and
   streams it slowly, counting the bytes it actually manages to write. A probe that
   cancels after the response headers leaves that count far below the advertised length,
   which is the evidence the header-only behaviour needs - "the code looks like it
   cancels" is not evidence.

`GET /seen` reports what the server actually observed, so the assertions are made
against the server's own accounting rather than against the client's intentions.

Usage:  python ua_gated_panel.py [port]
"""

import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

#: Markers a panel looks for when deciding whether a client is Clash-family.
CLASH_MARKERS = ("clash", "mihomo", "flclash", "verge", "stash", "surge")

BODY = b'{"outbounds":[{"type":"direct","tag":"direct"}]}'
QUOTA = "upload=161061273600; download=0; total=429496729600; expire=5"

#: The large endpoint. 8 MiB advertised, written in 64 KiB chunks with a pause between
#: them, so a full transfer takes seconds and a cancelled one is unmistakable.
BIG_LENGTH = 8 * 1024 * 1024
BIG_CHUNK = 64 * 1024
BIG_CHUNK_DELAY = 0.02

_lock = threading.Lock()
_seen = []
_big = {"content_length": BIG_LENGTH, "bytes_sent": 0, "completed": False, "transfers": 0}


def _record(path, headers):
    with _lock:
        _seen.append({
            "path": path,
            "user_agent": headers.get("User-Agent", ""),
            "cache_control": headers.get("Cache-Control", ""),
            "pragma": headers.get("Pragma", ""),
        })


def _snapshot():
    with _lock:
        return {"requests": list(_seen), "big": dict(_big)}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):  # noqa: N802
        if self.path.startswith("/seen"):
            self._json(200, json.dumps(_snapshot()).encode())
            return

        ua = self.headers.get("User-Agent", "")
        _record(self.path, self.headers)
        gated = any(marker in ua.lower() for marker in CLASH_MARKERS)

        if self.path.startswith("/big"):
            self._big(gated)
            return

        headers = {"Cache-Control": "max-age=3600"}
        if gated:
            headers["subscription-userinfo"] = QUOTA
        self._json(200, BODY, headers)

    def _big(self, gated):
        """Advertise a large body, then stream it slowly, counting what actually goes out."""
        with _lock:
            _big["transfers"] += 1
            _big["bytes_sent"] = 0
            _big["completed"] = False

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(BIG_LENGTH))
        self.send_header("Cache-Control", "max-age=3600")
        self.send_header("Connection", "close")
        if gated:
            self.send_header("subscription-userinfo", QUOTA)
        self.end_headers()

        chunk = b"x" * BIG_CHUNK
        sent = 0
        try:
            while sent < BIG_LENGTH:
                self.wfile.write(chunk)
                self.wfile.flush()
                sent += len(chunk)
                with _lock:
                    _big["bytes_sent"] = sent
                time.sleep(BIG_CHUNK_DELAY)
            with _lock:
                _big["completed"] = True
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            # The client stopped reading. That is the behaviour under test, not an error.
            pass
        finally:
            with _lock:
                _big["bytes_sent"] = sent
            self.close_connection = True

    def _json(self, status, payload, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        # One request per connection. The client's metadata probe uses its own short-lived
        # session, so a connection held open for keep-alive would leave a single-threaded
        # server unable to accept the next one - which shows up as the client timing out
        # rather than as the fixture being wrong.
        self.send_header("Connection", "close")
        for key, value in (extra or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.close_connection = True
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8791
    print(f"mock panel on http://127.0.0.1:{port}/ (sub, big, seen)", flush=True)
    # Threaded as well as connection-per-request: the large endpoint streams for seconds while
    # the probe's own session is opening, so the two must be able to overlap.
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
