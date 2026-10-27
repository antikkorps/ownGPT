"""Fake upstreams for test-caddy.sh: answers 200 on the Open WebUI, LiteLLM and
Authentik ports and reports which X-OpenWebUI-* headers reached it."""
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def _reply(self):
        leaked = sorted(h for h in self.headers if h.lower().startswith("x-openwebui-"))
        body = json.dumps({"path": self.path, "openwebui_headers": leaked}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = _reply

    def log_message(self, *args):
        pass


for port in (4000, 8080, 9000):
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
threading.Event().wait()
