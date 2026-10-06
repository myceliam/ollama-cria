"""Run inside OWUI after copying the two source files to /tmp.

Uses the existing admin API key in memory and preserves tool access/valves.
Never prints authentication material or source text.
"""
import ast
import json
import sqlite3
from pathlib import Path

import requests

DB = "file:/app/backend/data/webui.db?mode=ro"
BASE = "http://127.0.0.1:8080/api/v1/tools"
IDS = ("cited_analysis", "self_osint_footprint_recon_removal_uk")


def main():
    db = sqlite3.connect(DB, uri=True)
    key = db.execute(
        'SELECT a.key FROM api_key a JOIN user u ON a.user_id=u.id WHERE u.role="admin" LIMIT 1'
    ).fetchone()[0]
    session = requests.Session()
    session.headers["Authorization"] = f"Bearer {key}"
    for tid in IDS:
        source = Path(f"/tmp/{tid}.py").read_text(encoding="utf-8-sig")
        ast.parse(source)
        result = session.get(f"{BASE}/id/{tid}", timeout=20)
        result.raise_for_status()
        original = result.json()
        payload = {k: original[k] for k in ("id", "name", "meta", "access_grants") if k in original}
        payload["content"] = source
        response = session.post(f"{BASE}/id/{tid}/update", json=payload, timeout=60)
        response.raise_for_status()
        installed = session.get(f"{BASE}/id/{tid}", timeout=20).json()
        # OWUI rewrites import-like text even inside comments. Compare executable AST.
        assert ast.dump(ast.parse(installed["content"])) == ast.dump(ast.parse(source)), f"Source mismatch: {tid}"
        assert installed.get("access_grants") == original.get("access_grants"), "Access changed"
        assert installed.get("valves") == original.get("valves"), "Valves changed"
        print(f"Updated and verified {tid}; existing access and valves preserved")


if __name__ == "__main__":
    main()
