"""Run inside open-webui: back up skills, deploy the Brave Command Router (global filter) and its brave-* skills.

Usage (PowerShell, from E:\\ai\\ollama\\owui-tools):
  docker cp brave_command_router.py open-webui:/tmp/brave_command_router.py
  docker cp deploy_brave_command_router.py open-webui:/tmp/deploy_brave_command_router.py
  docker exec open-webui python /tmp/deploy_brave_command_router.py
"""

import base64
import hashlib
import hmac
import importlib.util
import json
import os
import sqlite3
import sys
import time
import types
import urllib.error
import urllib.request

DB = "/app/backend/data/webui.db"
API = "http://localhost:8080"
FUNCTION_ID = "brave_command_router"
SOURCE_PATH = "/tmp/brave_command_router.py"
NAME = "Brave Command Router"
DESCRIPTION = (
    "Global filter. Turns !commands (or a picked brave-* skill) into guaranteed Brave tool calls before the model runs, "
    "then hands the model the finished results. Messages without a command are untouched. Same protected route; no fallback."
)
BACKUP = f"/tmp/skills_backup_{time.strftime('%Y%m%d-%H%M%S')}.json"


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


# Load the command table from the router source (single source of truth).
spec = importlib.util.spec_from_file_location("brave_command_router", SOURCE_PATH)
router = importlib.util.module_from_spec(spec)
spec.loader.exec_module(router)

con = sqlite3.connect(DB)
con.row_factory = sqlite3.Row
admin_id = con.execute("SELECT id FROM user WHERE role='admin' ORDER BY created_at LIMIT 1").fetchone()[0]
skills_before = [dict(r) for r in con.execute("SELECT * FROM skill")]
existing_fn = con.execute("SELECT is_active, is_global FROM function WHERE id=?", (FUNCTION_ID,)).fetchone()
existing_skill_ids = {r["id"] for r in skills_before}
con.close()
with open(BACKUP, "w", encoding="utf-8") as handle:
    json.dump(skills_before, handle, indent=2, default=str)
print(f"skills backup: {BACKUP} ({len(skills_before)} rows)")

token = forge_jwt(admin_id, os.environ["WEBUI_SECRET_KEY"])

# 1. Filter function
source = open(SOURCE_PATH, encoding="utf-8").read()
form = {"id": FUNCTION_ID, "name": NAME, "content": source, "meta": {"description": DESCRIPTION, "manifest": {}}}
path = f"/api/v1/functions/id/{FUNCTION_ID}/update" if existing_fn else "/api/v1/functions/create"
status, result = call("POST", path, form, token)
print(f"function {'update' if existing_fn else 'create'}: HTTP {status} type={result.get('type')}")
if not (existing_fn and existing_fn[0]):
    status, result = call("POST", f"/api/v1/functions/id/{FUNCTION_ID}/toggle", None, token)
    print(f"active toggle: HTTP {status} active={result.get('is_active')}")
if not (existing_fn and existing_fn[1]):
    status, result = call("POST", f"/api/v1/functions/id/{FUNCTION_ID}/toggle/global", None, token)
    print(f"global toggle: HTTP {status} global={result.get('is_global')}")

# 2. One brave-* skill per command
RULES = (
    "Rules: text in \"double quotes\"; +sources adds numbered citations; ; separates commands; "
    "-- note after a command = instruction for that section; a final ; -- note = instruction for the whole answer."
)
# Menu chips to create. Liam removed every Brave chip on 12 Oct 2026 (the Command Guide's builder replaces them).
# Names here must be keys of router.CHIPS; every command, and every chip name as an alias, still works typed.
MENU_CHIPS: list[str] = []
for chip in MENU_CHIPS:
    name = router.CHIPS[chip]
    cmd = router.COMMANDS[name]
    sid = router.SKILL_PREFIX + chip
    tool_line = f"Runs {cmd['tool']}.{cmd['fn']} deterministically." if cmd["tool"] else "Shows the full command reference."
    description = f"({router.TOOL_TAGS[cmd['tool']]}) {cmd['usage']}  —  {cmd['does']} {tool_line}"
    content = (
        f"# {sid} (= !{name})\n\n**What it does:** {cmd['does']}\n\n**Syntax:** `{cmd['usage']}`\n\n{RULES}\n\n"
        "This skill is a command chip. The Brave Command Router filter normally converts it into a guaranteed tool call "
        "before you (the model) see the message, so you should never read this text. If you ARE reading it, the router "
        f"is disabled: call `{cmd['tool'] or 'none'}`.`{cmd['fn'] or '-'}` once with the arguments given in the user's message, "
        "set include_sources true only if +sources is present, then write the answer from the result."
    )
    form = {"id": sid, "name": sid, "description": description, "content": content,
            "meta": {"tags": ["brave", "command"]}, "is_active": True}
    if sid in existing_skill_ids:
        status, _ = call("POST", f"/api/v1/skills/id/{sid}/update", form, token)
        print(f"skill update {sid}: HTTP {status}")
    else:
        status, _ = call("POST", "/api/v1/skills/create", form, token)
        print(f"skill create {sid}: HTTP {status}")

# 3. /mermaid - general diagram skill (not Brave; prompt text for the model)
MERMAID = {
    "id": "mermaid", "name": "mermaid",
    "description": "(DIAGRAM) /mermaid <what to draw> — Draws a parser-safe Mermaid diagram (flowchart, sequence, timeline, mindmap, state, ER) of what you describe or of the conversation so far.",
    "content": """# /mermaid — draw a diagram

Draw a Mermaid diagram of what the user describes after the command (or, if nothing is written, of the most recent topic in this conversation).

## Pick the right type
| Use | Mermaid type |
|---|---|
| Process, pipeline, decision, architecture | `flowchart TD` (or `LR` for wide pipelines) |
| Who calls whom, request/response | `sequenceDiagram` |
| Events over time | `timeline` |
| Concept map / brainstorm | `mindmap` |
| States and transitions | `stateDiagram-v2` |
| Data model | `erDiagram` |

## Rules that keep it rendering in Open WebUI
1. One fenced block: ```mermaid ... ``` and nothing else inside it.
2. Short stable node IDs (`gw`, `vps`, `db`), human text only in labels.
3. **Every flowchart label in double quotes**: `gw["Gateway (VPS)"]`, `d{"Healthy?"}`. Never unquoted labels with brackets, colons, slashes or commas.
4. Edge labels quoted too: `a -->|"over Tailscale"| b`.
5. Use `flowchart`, not the legacy `graph`. No `%%{init}%%` themes, no HTML tags, no emoji inside node IDs.
6. Keep it readable: at most ~20 nodes; group with `subgraph id["Title"] ... end` when there are clear zones.
7. After the block, give a 2–4 line plain-English explanation of what the diagram shows.

If the request is ambiguous, draw the most useful interpretation rather than asking.""",
}
# Diagram skills are now managed by the diagram work (12 Oct 2026), so this only runs on request.
existing_all = {r[0] for r in sqlite3.connect(DB).execute("SELECT id FROM skill")}
if "--with-mermaid" in sys.argv:
    form = {**MERMAID, "meta": {"tags": ["diagram"]}, "is_active": True}
    status, _ = call("POST", f"/api/v1/skills/id/mermaid/update" if "mermaid" in existing_all else "/api/v1/skills/create", form, token)
    print(f"skill mermaid: HTTP {status}")

# 4. Retire brave-* skills that are no longer chips (backed up above) when asked. Other skills are never touched.
if "--retire-legacy" in sys.argv:
    keep = {router.SKILL_PREFIX + c for c in MENU_CHIPS}
    for sid in sorted(s for s in existing_all - keep if s.startswith(router.SKILL_PREFIX)):
        status, _ = call("DELETE", f"/api/v1/skills/id/{sid}/delete", None, token)
        print(f"legacy skill deleted {sid}: HTTP {status}")

con = sqlite3.connect(DB)
row = con.execute("SELECT is_active, is_global, content FROM function WHERE id=?", (FUNCTION_ID,)).fetchone()
print("verify function active/global:", row[0], row[1], "sha256", hashlib.sha256(row[2].encode()).hexdigest()[:16])
print("verify local  sha256:", hashlib.sha256(source.encode()).hexdigest()[:16])
print("verify brave skills active:", con.execute("SELECT count(*) FROM skill WHERE id LIKE 'brave-%' AND is_active=1").fetchone()[0], "of", len(MENU_CHIPS))
print("verify other skills now:", [r[0] for r in con.execute("SELECT id FROM skill WHERE id NOT LIKE 'brave-%'")])
