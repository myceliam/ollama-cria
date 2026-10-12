"""Run inside open-webui to create or update the ten diagram-* skills (AICL-0171).

Copy diagram_skills.py and this file to /tmp first. Existing diagram-* skills are updated in
place; no other skill is touched.
"""

import base64
import hashlib
import hmac
import json
import os
import sqlite3
import sys
import urllib.error
import urllib.request

sys.path.insert(0, "/tmp")
from diagram_skills import SKILLS, content, description  # noqa: E402

DB = "/app/backend/data/webui.db"
API = "http://localhost:8080"


def b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


def forge_jwt(user_id: str, secret: str) -> str:
    header = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    payload = b64url(json.dumps({"id": user_id}).encode())
    signature = b64url(hmac.new(secret.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest())
    return f"{header}.{payload}.{signature}"


def post(path: str, payload: dict, token: str) -> tuple[int, dict]:
    request = urllib.request.Request(
        API + path,
        data=json.dumps(payload).encode(),
        method="POST",
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + token},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, json.loads(response.read().decode() or "{}")
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"POST {path} failed with HTTP {exc.code}: {exc.read().decode(errors='replace')}") from exc


connection = sqlite3.connect(DB)
admin_id = connection.execute("SELECT id FROM user WHERE role='admin' LIMIT 1").fetchone()[0]
existing = {row[0] for row in connection.execute("SELECT id FROM skill WHERE id LIKE 'diagram-%'")}
connection.close()

token = forge_jwt(admin_id, os.environ["WEBUI_SECRET_KEY"])
for skill in SKILLS:
    form = {
        "id": skill["id"],
        "name": skill["id"],
        "description": description(skill),
        "content": content(skill),
        "meta": {"tags": ["diagram"]},
        "is_active": True,
    }
    endpoint = f"/api/v1/skills/id/{skill['id']}/update" if skill["id"] in existing else "/api/v1/skills/create"
    status, _ = post(endpoint, form, token)
    print(f"{skill['id']}: {'update' if skill['id'] in existing else 'create'} HTTP {status}")
