"""A mock subscription panel that gates `subscription-userinfo` on the User-Agent.

Reproduces the behaviour satelite-one's own source documents as the reason it masquerades
as a Clash client:
    "UA masquerades as clash-verge so panels return the subscription-userinfo header."
    -- satelite-one, SubscriptionFetcher.kt:13

Serves a fixed sing-box body for every request, and the quota header ONLY when the
request's User-Agent contains a Clash-family marker. Records every request's UA so the
A/B can show what each transport actually sent, rather than what the source says it sends.

Usage:  python ua_gated_panel.py <port>
Endpoint:  GET /sub          -> gated response
           GET /seen         -> JSON list of every User-Agent seen so far
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

CLASH_MARKERS = ("clash", "mihomo", "flclash", "verge", "stash", "surge")

BODY = b'{"outbounds":[{"type":"direct","tag":"direct"}]}'
QUOTA = "upload=161061273600; download=0; total=429496729600; expire=5"

seen = []


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):  # noqa: N802
        if self.path.startswith("/seen"):
            payload = json.dumps(seen).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        ua = self.headers.get("User-Agent", "")
        seen.append({"path": self.path, "user_agent": ua})

        gated = any(marker in ua.lower() for marker in CLASH_MARKERS)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(BODY)))
        self.send_header("Cache-Control", "max-age=3600")
        if gated:
            self.send_header("subscription-userinfo", QUOTA)
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8791
    print(f"ua-gated mock panel on http://127.0.0.1:{port}/sub", flush=True)
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
