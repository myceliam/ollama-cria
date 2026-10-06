"""Run inside open-webui: real calls using OWUI's saved server credentials."""
import json
import sqlite3
import sys
import types
from concurrent.futures import ThreadPoolExecutor

import requests

db = sqlite3.connect("file:/app/backend/data/webui.db?mode=ro", uri=True)
servers = json.loads(db.execute("SELECT value FROM config WHERE key='tool_server.connections'").fetchone()[0])
selected = {s["url"].rsplit("/", 1)[-1]: s for s in servers if s.get("url", "").endswith(("/web_search", "/jina_reader"))}


def call(name, method, payload):
    server = selected[name]
    response = requests.post(
        server["url"] + "/" + method,
        json=payload,
        headers={"Authorization": "Bearer " + server["key"]},
        timeout=100,
    )
    response.raise_for_status()
    body = response.text
    assert len(body) > 80, (method, body)
    assert not any(x in body.lower() for x in ("connection refused", "internal server error")), method
    print(method, response.status_code, body[:400])
    return body


jobs = [
    ("web_search", "searxng_web_search", {"query": "IANA example domains", "num_results": 3}),
    ("web_search", "web_url_read", {"url": "https://am.i.mullvad.net/json", "maxLength": 1500}),
    ("jina_reader", "read_url", {"url": "https://am.i.mullvad.net/json", "timeout_seconds": 60}),
]
with ThreadPoolExecutor(max_workers=3) as executor:
    results = list(executor.map(lambda args: call(*args), jobs))
assert "iana" in results[0].lower(), "Search returned no IANA result"
for body in results[1:]:
    body = body.replace("\\", "")  # Markdown readers escape underscores in JSON keys.
    assert "mullvad_exit_ip" in body and "true" in body.lower() and "gb-lon-wg-001" in body, body

for tid in ("cited_analysis", "self_osint_footprint_recon_removal_uk"):
    content, valves = db.execute("SELECT content,valves FROM tool WHERE id=?", (tid,)).fetchone()
    module = types.ModuleType("verify_" + tid)
    sys.modules[module.__name__] = module
    exec(compile(content, tid, "exec"), module.__dict__)
    tool = module.Tools()
    tool.valves = tool.Valves(**json.loads(valves or "{}"))
    if tid == "cited_analysis":
        assert "Example Domain" in tool._fetch("https://example.com")
        calls = []
        def fail(url, **kwargs):
            calls.append(url)
            response = requests.Response()
            response.status_code = 502
            response._content = b"Reader unavailable"
            return response
        module.requests = types.SimpleNamespace(get=fail)
        assert "FETCH FAILED" in tool._fetch("https://example.com")
        assert len(calls) == 1 and calls[0].startswith("http://jina-reader:3000/"), calls
    else:
        backend, text = tool._read_chain("https://example.com")
        assert backend == "jina-reader" and "Example Domain" in text
        tool._fetch_jina = lambda url: None
        def forbidden(url):
            raise AssertionError("Unprotected fallback was attempted")
        tool._fetch_webfetch = tool._fetch_raw = forbidden
        assert tool._read_chain("https://example.com") == (None, None)
    print(tid, "live page read and no-direct-fallback test PASS")
print("ALL OWUI SEARCH/READER CHECKS PASSED")
