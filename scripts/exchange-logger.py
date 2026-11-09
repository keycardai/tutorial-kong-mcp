"""A pass-through that logs each token exchange Kong sends, then forwards it.

Point the Request Callout's URL at http://host.docker.internal:8099/oauth/2/token
to see exactly what Kong asks your Zone for on every MCP call, and what the
Zone answers. Tokens and secrets are never logged: they show as a short
fingerprint, so you can tell two apart without seeing either.

    KEYCARD_TOKEN_URL=https://<zone-id>.keycard.cloud/oauth/2/token python3 scripts/exchange-logger.py
"""

import base64
import hashlib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("KEYCARD_TOKEN_URL", "")
PORT = int(os.environ.get("PORT", "8099"))
LOG_FILE = os.environ.get("EXCHANGE_LOG", "exchange-log.jsonl")


def fingerprint(value: str) -> str:
    return "sha256:" + hashlib.sha256(value.encode()).hexdigest()[:10] if value else ""


def client_id_from_basic(header: str) -> str:
    if not header.lower().startswith("basic "):
        return ""
    try:
        return base64.b64decode(header[6:]).decode().split(":", 1)[0]
    except Exception:
        return "(unreadable)"


class Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        form = {k: v[0] for k, v in urllib.parse.parse_qs(raw.decode(), keep_blank_values=True).items()}
        entry = {
            "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "content_type": self.headers.get("Content-Type", ""),
            "client_id": client_id_from_basic(self.headers.get("Authorization", "")),
            "grant_type": form.get("grant_type", ""),
            "resource": form.get("resource", ""),
            "authorization_details": form.get("authorization_details", ""),
            "subject_token": fingerprint(form.get("subject_token", "")),
            "subject_token_type": form.get("subject_token_type", ""),
            "other_fields": sorted(set(form) - {"grant_type", "resource", "authorization_details",
                                                "subject_token", "subject_token_type"}),
        }

        status, body = 502, b'{"error":"server_error","error_description":"KEYCARD_TOKEN_URL is not set"}'
        if UPSTREAM:
            # The Zone sits behind Cloudflare, which refuses Python's default
            # User-Agent with a plain-text "error code: 1010", so name the client.
            req = urllib.request.Request(UPSTREAM, data=raw, method="POST", headers={
                "Content-Type": self.headers.get("Content-Type", "application/x-www-form-urlencoded"),
                "Authorization": self.headers.get("Authorization", ""),
                "User-Agent": "kong-keycard-tutorial-exchange-logger/1.0",
            })
            try:
                with urllib.request.urlopen(req, timeout=15) as resp:
                    status, body = resp.status, resp.read()
            except urllib.error.HTTPError as err:
                status, body = err.code, err.read()

        try:
            answer = json.loads(body)
        except ValueError:
            # Kong's callout decodes the reply as JSON, so a non-JSON answer
            # would surface as an opaque 400. Wrap it so Kong reports why.
            text = body.decode(errors="replace").strip()[:200]
            answer = {"error": "server_error",
                      "error_description": f"token endpoint answered {status} with non-JSON: {text}"}
            body = json.dumps(answer).encode()
        entry["zone_status"] = status
        entry["zone_error"] = answer.get("error_description") or answer.get("error") or ""
        entry["issued_token"] = fingerprint(answer.get("access_token", ""))

        line = json.dumps(entry)
        print(line, flush=True)
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")

        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args) -> None:
        pass


if __name__ == "__main__":
    if not UPSTREAM:
        print("Set KEYCARD_TOKEN_URL to your Zone's token endpoint.", file=sys.stderr)
    print(f"Logging token exchanges on :{PORT}, forwarding to {UPSTREAM or '(nowhere)'}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
