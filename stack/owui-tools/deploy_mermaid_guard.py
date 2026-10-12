"""Run inside open-webui to create/update and globally enable Mermaid Render Guard."""

import base64
import hashlib
import hmac
import json
import os
import sqlite3
import urllib.error
import urllib.request

DB = "/app/backend/data/webui.db"
API = "http://localhost:8080"
FUNCTION_ID = "mermaid_render_guard"
SOURCE_PATH = "/tmp/mermaid_guard.py"
NAME = "Mermaid Render Guard"
DESCRIPTION = (
    "A narrow global filter that guides Mermaid flowcharts toward quoted node labels and repairs "
    "ordinary unquoted square-node labels plus unambiguous comma-separated fan-in/fan-out edges "
    "inside completed fenced flowchart blocks. It does not alter prose, other Mermaid grammars, "
    "non-Mermaid code blocks, networking, search, or source content."
)


def b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


def forge_jwt(user_id: str, secret: str) -> str:
    header = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    payload = b64url(json.dumps({"id": user_id}).encode())
    signature = b64url(hmac.new(secret.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest())
    return f"{header}.{payload}.{signature}"


def post(path: str, payload: dict | None, token: str) -> tuple[int, dict]:
    data = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(
        API + path,
        data=data,
        method="POST",
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + token},
    )
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            return response.status, json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        raise RuntimeError(f"POST {path} failed with HTTP {exc.code}: {detail}") from exc


connection = sqlite3.connect(DB)
row = connection.execute("SELECT id FROM user WHERE role='admin' LIMIT 1").fetchone()
if row is None:
    raise RuntimeError("No Open WebUI admin user exists")
admin_id = row[0]
existing = connection.execute(
    "SELECT is_active, is_global FROM function WHERE id=?", (FUNCTION_ID,)
).fetchone()
connection.close()

token = forge_jwt(admin_id, os.environ["WEBUI_SECRET_KEY"])
source = open(SOURCE_PATH, encoding="utf-8").read()
form = {
    "id": FUNCTION_ID,
    "name": NAME,
    "content": source,
    "meta": {"description": DESCRIPTION, "manifest": {}},
}
endpoint = f"/api/v1/functions/id/{FUNCTION_ID}/update" if existing else "/api/v1/functions/create"
status, result = post(endpoint, form, token)
print(f"function {'update' if existing else 'create'}: HTTP {status} type={result.get('type')}")

is_active = bool(existing[0]) if existing else False
is_global = bool(existing[1]) if existing else False
if not is_active:
    status, result = post(f"/api/v1/functions/id/{FUNCTION_ID}/toggle", None, token)
    print(f"active toggle: HTTP {status} active={result.get('is_active')}")
if not is_global:
    status, result = post(f"/api/v1/functions/id/{FUNCTION_ID}/toggle/global", None, token)
    print(f"global toggle: HTTP {status} global={result.get('is_global')}")
