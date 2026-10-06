#!/usr/bin/env python3
"""Controlled Brave/Jina fail-closed check; always restores Gluetun in finally."""

import json
import time
import urllib.error
import urllib.request


VPN = "http://127.0.0.1:8000/v1/vpn/status"
GATEWAY = "http://127.0.0.1:13100"


def vpn(status: str) -> None:
    request = urllib.request.Request(
        VPN,
        data=json.dumps({"status": status}).encode(),
        headers={"Content-Type": "application/json"},
        method="PUT",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        response.read()


def call(path: str, body: dict, timeout: int = 35) -> dict:
    request = urllib.request.Request(
        GATEWAY + path,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)
    except (TimeoutError, urllib.error.URLError) as exc:
        return {"status": "transport_timeout", "detail": type(exc).__name__}


try:
    vpn("stopped")
    time.sleep(3)
    search_down = call("/search", {"query": "kill switch verification", "count": 1}, 50)
    reader_down = call("/read-url", {"url": "https://example.com", "options": {"engine": "browser", "timeout": 8}}, 35)
    print("vpn_stopped_search_status=" + str(search_down.get("status")))
    print("vpn_stopped_reader_status=" + str(reader_down.get("status")))
    if search_down.get("status") not in {"network_error", "provider_error", "transport_timeout"}:
        raise SystemExit("Brave did not fail closed while VPN was stopped")
    # public_url() resolves before handing off to Jina, so tunnel DNS loss is
    # reported as unsafe_url/unresolvable rather than trying another resolver.
    if reader_down.get("status") not in {"unsafe_url", "reader_error", "empty_page", "blocked", "transport_timeout"}:
        raise SystemExit("Jina did not fail closed while VPN was stopped")
finally:
    vpn("running")

for attempt in range(12):
    time.sleep(3)
    recovered = call("/search", {"query": "UK Parliament", "count": 1})
    if recovered.get("status") == "ok":
        print("vpn_recovered_search_status=ok")
        break
else:
    raise SystemExit("VPN did not recover within the verification window")
