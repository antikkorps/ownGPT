"""Minimal Open WebUI REST client used by import_seed.py (stdlib only)."""
import json
import os
import urllib.error
import urllib.request
import uuid

BASE = "http://localhost:8080"


class Api:
    def __init__(self):
        self.token = None

    def call(self, method, path, body=None, raw=None, content_type="application/json"):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        headers = {"Content-Type": content_type}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        req = urllib.request.Request(BASE + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                text = r.read().decode()
                return json.loads(text) if text else None
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"{method} {path} -> {e.code} {e.read().decode()[:300]}") from None

    def try_call(self, *args, **kwargs):
        try:
            return self.call(*args, **kwargs)
        except RuntimeError:
            return None

    def signin(self):
        auth = self.call("POST", "/api/v1/auths/signin", {
            "email": os.environ["WEBUI_ADMIN_EMAIL"], "password": os.environ["WEBUI_ADMIN_PASSWORD"]})
        self.token = auth["token"]

    def upload(self, path):
        boundary = uuid.uuid4().hex
        with open(path, "rb") as f:
            payload = f.read()
        name = os.path.basename(path)
        body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\n"
                f"Content-Type: text/markdown\r\n\r\n").encode() + payload + f"\r\n--{boundary}--\r\n".encode()
        return self.call("POST", "/api/v1/files/", raw=body,
                         content_type=f"multipart/form-data; boundary={boundary}")


def items(response):
    # List endpoints return either a bare list or {"items": [...]} depending on the route.
    return response.get("items", []) if isinstance(response, dict) else (response or [])

