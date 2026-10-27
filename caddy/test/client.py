"""Sends one request through Caddy and prints "<status> <body>" (used by test-caddy.sh).
Usage: client.py <METHOD> <host> <path> [Header: value ...]
HTTPS mode (TLS test): CAFILE=<root.crt> connects to https://<host> and checks the
certificate against that CA only."""
import os
import ssl
import sys
import urllib.error
import urllib.request

method, host, path, *headers = sys.argv[1:]
cafile = os.environ.get("CAFILE")
url = f"https://{host}{path}" if cafile else f"http://caddy{path}"
if cafile:
    ssl_ctx = ssl.create_default_context(cafile=cafile)
    urllib.request.install_opener(urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=ssl_ctx),
        # Report redirects instead of following them (HTTP→HTTPS check).
        type("NoRedirect", (urllib.request.HTTPRedirectHandler,), {"redirect_request": lambda *a, **k: None})()))
req = urllib.request.Request(url, method=method,
                             data=b"{}" if method == "POST" else None,
                             headers={"Host": host, **dict(h.split(": ", 1) for h in headers)})
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        print(r.status, r.read().decode())
except urllib.error.HTTPError as e:
    print(e.code, e.read().decode()[:100])
except Exception as e:  # connection reset, malformed URL…: never a pass
    print("ERR", type(e).__name__)
