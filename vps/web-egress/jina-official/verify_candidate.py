#!/usr/bin/env python3
"""Side-by-side smoke and SSRF checks for the official Jina candidate."""

import json
import urllib.error
import urllib.parse
import urllib.request

BASE = "http://127.0.0.1:3101/"


def read(label: str, target: str, timeout: int = 90, extra_headers: dict[str, str] | None = None) -> tuple[int, str]:
    headers = {"X-No-Cache": "true", "X-Timeout": "20", "X-Respond-With": "markdown"}
    headers.update(extra_headers or {})
    request = urllib.request.Request(
        BASE + target,
        headers=headers,
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read(250_000).decode("utf-8", errors="replace")
            code = response.status
    except urllib.error.HTTPError as exc:
        code = exc.code
        body = exc.read(20_000).decode("utf-8", errors="replace")
    except Exception as exc:
        code = 0
        body = f"{type(exc).__name__}: {exc}"
    print(json.dumps({"label": label, "status": code, "chars": len(body), "head": body[:160]}))
    return code, body


normal_code, normal = read("normal", "https://example.com/")
browser_code, browser = read("forced-browser", "https://example.com/", extra_headers={"X-Engine": "browser"})
pdf_code, pdf = read("pdf", "https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf", 120)
exit_code, exit_body = read("vpn-exit", "https://am.i.mullvad.net/json")
literal_code, literal = read("private-literal", "http://127.0.0.1:8000/v1/vpn/status")
dns_code, dns_body = read("private-dns", "http://127.0.0.1.nip.io:8000/v1/vpn/status")
redirect_target = "https://httpbin.org/redirect-to?url=" + urllib.parse.quote(
    "http://127.0.0.1:8000/v1/vpn/status", safe=""
)
redirect_code, redirect = read("private-redirect", redirect_target)

checks = {
    "normal_ok": normal_code == 200 and "Example Domain" in normal,
    "browser_ok": browser_code == 200 and "Example Domain" in browser,
    "pdf_ok": pdf_code == 200 and len(pdf) > 200,
    "vpn_exit_ok": exit_code == 200 and "mullvad_exit_ip" in exit_body and "true" in exit_body.lower(),
    "literal_blocked": literal_code != 200 or '"status":"running"' not in literal.replace(" ", ""),
    "dns_blocked": dns_code != 200 or '"status":"running"' not in dns_body.replace(" ", ""),
    "redirect_blocked": redirect_code != 200 or '"status":"running"' not in redirect.replace(" ", ""),
}
print(json.dumps({"checks": checks, "all_passed": all(checks.values())}))
raise SystemExit(0 if all(checks.values()) else 1)
