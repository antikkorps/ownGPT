"""Sends one request through Caddy and prints "<status> <body>" (used by test-caddy.sh).
Usage: client.py <METHOD> <host> <path> [Header: value ...]"""
import sys
import urllib.error
import urllib.request

method, host, path, *headers = sys.argv[1:]
req = urllib.request.Request(f"http://caddy{path}", method=method,
                             data=b"{}" if method == "POST" else None,
                             headers={"Host": host, **dict(h.split(": ", 1) for h in headers)})
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        print(r.status, r.read().decode())
except urllib.error.HTTPError as e:
    print(e.code, e.read().decode()[:100])
except Exception as e:  # connection reset, malformed URL…: never a pass
    print("ERR", type(e).__name__)
