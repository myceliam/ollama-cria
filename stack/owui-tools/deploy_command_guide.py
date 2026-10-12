"""Run inside open-webui: create or update the Command Guide model (a dictionary of every command; it runs nothing).

Usage (PowerShell, from E:\\ai\\ollama\\owui-tools):
  docker cp command_guide_system_prompt.md open-webui:/tmp/command_guide_system_prompt.md
  docker cp command_builder.py open-webui:/tmp/command_builder.py
  docker cp deploy_command_guide.py open-webui:/tmp/deploy_command_guide.py
  docker exec open-webui python /tmp/deploy_command_guide.py
"""

import base64
import hashlib
import hmac
import json
import os
import sqlite3
import time
import urllib.error
import urllib.request

DB = "/app/backend/data/webui.db"
API = "http://localhost:8080"
MODEL_ID = "q_command-guide:8b"
BASE_MODEL = "granite4.2:8b"
PROMPT_PATH = "/tmp/command_guide_system_prompt.md"
BUILDER_PATH = "/tmp/command_builder.py"
BUILDER_ID = "command_builder"
BACKUP_DIR = f"/app/backend/data/model-backups/command-guide-{time.strftime('%Y%m%d-%H%M%S')}"


def b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


def forge_jwt(user_id: str, secret: str) -> str:
    header = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}).encode())
    payload = b64url(json.dumps({"id": user_id}).encode())
    signature = b64url(hmac.new(secret.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest())
    return f"{header}.{payload}.{signature}"


def call(method: str, path: str, payload: dict | None, token: str) -> tuple[int, object]:
    data = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(API + path, data=data, method=method,
                                     headers={"Content-Type": "application/json", "Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            return response.status, json.loads(response.read().decode() or "null")
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"{method} {path} failed with HTTP {exc.code}: {exc.read().decode(errors='replace')[:400]}") from exc


system = open(PROMPT_PATH, encoding="utf-8").read()
con = sqlite3.connect(DB)
con.row_factory = sqlite3.Row
admin_id = con.execute("SELECT id FROM user WHERE role='admin' ORDER BY created_at LIMIT 1").fetchone()[0]
existing = con.execute("SELECT * FROM model WHERE id=?", (MODEL_ID,)).fetchone()
con.close()
if existing:
    os.makedirs(BACKUP_DIR, exist_ok=True)
    with open(f"{BACKUP_DIR}/before.json", "w", encoding="utf-8") as handle:
        json.dump(dict(existing), handle, indent=2, default=str)
    print("backup:", BACKUP_DIR)

token = forge_jwt(admin_id, os.environ["WEBUI_SECRET_KEY"])

# Command Builder filter: active, NOT global, attached to this model only through meta.filterIds.
builder_source = open(BUILDER_PATH, encoding="utf-8").read()
con = sqlite3.connect(DB)
builder = con.execute("SELECT is_active, is_global FROM function WHERE id=?", (BUILDER_ID,)).fetchone()
con.close()
bform = {"id": BUILDER_ID, "name": "Command Builder", "content": builder_source,
         "meta": {"description": "Command Guide only: 'build brave command' opens popups and returns a finished command.", "manifest": {}}}
status, _ = call("POST", f"/api/v1/functions/id/{BUILDER_ID}/update" if builder else "/api/v1/functions/create", bform, token)
print(f"builder {'update' if builder else 'create'}: HTTP {status}")
if not (builder and builder[0]):
    status, result = call("POST", f"/api/v1/functions/id/{BUILDER_ID}/toggle", None, token)
    print("builder active:", result.get("is_active"))
if builder and builder[1]:
    status, result = call("POST", f"/api/v1/functions/id/{BUILDER_ID}/toggle/global", None, token)
    print("builder global turned off:", result.get("is_global"))

form = {
    "id": MODEL_ID,
    "base_model_id": BASE_MODEL,
    "name": "📖 Command Guide",
    "meta": {
        "profile_image_url": "/static/favicon.png",
        "description": "Dictionary of every Brave command and diagram skill. Ask in plain words (e.g. \"list all the Brave commands\"); "
                       "it explains each one and gives a copy-ready command. It runs nothing.",
        "capabilities": {"vision": False, "file_upload": False, "web_search": False, "image_generation": False,
                         "code_interpreter": False, "citations": False},
        "suggestion_prompts": [
            {"content": "build brave command"},
            {"content": "Give me a list of all the Brave commands"},
            {"content": "Which command should I use to compare two things?"},
            {"content": "List all the diagram skills"},
        ],
        "tags": [{"name": "Guide"}],
        "filterIds": [BUILDER_ID],
    },
    "params": {"system": system, "temperature": 0.1, "num_ctx": 32768},
    "is_active": True,
}
path = f"/api/v1/models/model/update" if existing else "/api/v1/models/create"
status, _ = call("POST", path, form, token)
print(f"model {'update' if existing else 'create'}: HTTP {status}")

row = sqlite3.connect(DB).execute("SELECT base_model_id, is_active, params FROM model WHERE id=?", (MODEL_ID,)).fetchone()
stored = json.loads(row[2]).get("system", "")
print("verify base/active:", row[0], row[1])
meta = json.loads(sqlite3.connect(DB).execute("SELECT meta FROM model WHERE id=?", (MODEL_ID,)).fetchone()[0])
fn = sqlite3.connect(DB).execute("SELECT is_active, is_global, content FROM function WHERE id=?", (BUILDER_ID,)).fetchone()
print("verify filterIds:", meta.get("filterIds"), "| builder active/global:", fn[0], fn[1],
      "| sha256 stored/local:", hashlib.sha256(fn[2].encode()).hexdigest()[:16], hashlib.sha256(builder_source.encode()).hexdigest()[:16])
print("verify system prompt sha256 stored/local:", hashlib.sha256(stored.encode()).hexdigest()[:16], hashlib.sha256(system.encode()).hexdigest()[:16])
