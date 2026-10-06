#!/usr/bin/env python3
"""Tailnet-only Brave + Jina gateway.

The container shares Gluetun's network namespace.  Consequently every public
request made here, and every Jina request it delegates, is subject to the same
Mullvad multihop tunnel and kill switch.  There is deliberately no alternate
search provider and no direct-egress fallback.
"""

from __future__ import annotations

import concurrent.futures
import ipaddress
import json
import os
import re
import socket
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any


LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 13100
BRAVE_SEARCH = "https://api.search.brave.com/res/v1/web/search"
BRAVE_NEWS = "https://api.search.brave.com/res/v1/news/search"
BRAVE_VIDEOS = "https://api.search.brave.com/res/v1/videos/search"
BRAVE_CONTEXT = "https://api.search.brave.com/res/v1/llm/context"
JINA_BASE = "http://127.0.0.1:3000"
BRAVE_COUNTRY = "GB"
BRAVE_SEARCH_LANG = "en"
BRAVE_UI_LANG = "en-GB"
JINA_LOCALE = "en-GB"
ROUTE = "PC -> Tailscale -> VPS -> Gluetun/Mullvad multihop -> Internet"
MAX_REQUEST_BYTES = 64 * 1024
MAX_PAGE_CHARS = 24_000
MAX_LIBRARY_CHARS = 2_000_000
MAX_TOTAL_PAGE_CHARS = 96_000

FRESHNESS_RE = re.compile(r"^(?:pd|pw|pm|py|\d{4}-\d{2}-\d{2}to\d{4}-\d{2}-\d{2})$")
BLOCK_STRONG = (
    "our systems have detected unusual traffic",
    "attention required! | cloudflare",
    "checking your browser before accessing",
    "verify you are human",
    "enable javascript and cookies to continue",
    "please complete the security check",
)
BLOCK_WEAK = (
    "captcha",
    "are you a robot",
    "access denied",
    "request blocked",
    "request for access",
    "403 forbidden",
    "just a moment",
)
DEPTHS = {
    "quick": {"tokens": 4096, "urls": 8, "pages": 1},
    "standard": {"tokens": 8192, "urls": 12, "pages": 3},
    "deep": {"tokens": 16384, "urls": 20, "pages": 4},
}


def response(status: str, provider: str, message: str = "", **data: Any) -> dict[str, Any]:
    return {
        "status": status,
        "provider": provider,
        "route": ROUTE,
        "message": message,
        **data,
    }


def blocked_marker(text: str) -> str:
    body = (text or "").strip()
    head = body[:3000].lower()
    for marker in BLOCK_STRONG:
        if marker in head:
            return marker
    if len(body) < 4000:
        for marker in BLOCK_WEAK:
            if marker in head:
                return marker
    return ""


def public_url(raw_url: str) -> tuple[bool, str]:
    """Reject obvious SSRF targets before handing a URL to Jina.

    The nftables guard is still the final network boundary.  This check blocks
    literal and currently-resolved loopback, private, link-local, multicast and
    reserved addresses, including the cloud-metadata ranges.
    """
    try:
        parsed = urllib.parse.urlsplit((raw_url or "").strip())
        if parsed.scheme not in {"http", "https"} or not parsed.hostname:
            return False, "only absolute http/https URLs are accepted"
        if parsed.username or parsed.password:
            return False, "credentials in URLs are not accepted"
        port = parsed.port
        if port is not None and port not in {80, 443}:
            return False, "only destination ports 80 and 443 are accepted"
        addresses = {item[4][0] for item in socket.getaddrinfo(parsed.hostname, port or 443)}
        if not addresses:
            return False, "hostname did not resolve"
        for address in addresses:
            ip = ipaddress.ip_address(address)
            if not ip.is_global:
                return False, f"hostname resolves to non-public address {ip.compressed}"
        return True, ""
    except (OSError, ValueError) as exc:
        return False, f"invalid or unresolvable URL: {exc}"


def brave_error(http_status: int, payload: Any, operation: str) -> dict[str, Any]:
    code = ""
    detail = ""
    if isinstance(payload, dict):
        err = payload.get("error") or {}
        if isinstance(err, dict):
            code = str(err.get("code") or "").upper()
            detail = str(err.get("detail") or "")
    if code == "QUOTA_LIMITED":
        status = "quota_limited"
    elif code == "RATE_LIMITED" or http_status == 429:
        status = "rate_limited"
    elif http_status in {401, 403}:
        status = "auth_error"
    elif http_status == 422:
        status = "invalid_request"
    else:
        status = "provider_error"
    message = f"Brave {operation} failed with HTTP {http_status}"
    if code:
        message += f" ({code})"
    if detail:
        message += f": {detail[:300]}"
    return response(status, f"brave_{operation}", message, http_status=http_status, error_code=code)


def request_json(url: str, payload: dict[str, Any], operation: str, timeout: int = 35) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    key = os.environ.get("BRAVE_API_KEY", "").strip()
    if not key:
        return None, response("configuration_error", f"brave_{operation}", "BRAVE_API_KEY is not configured on the VPS")
    req = urllib.request.Request(
        url,
        data=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
        headers={
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-Subscription-Token": key,
            "User-Agent": "owui-brave-jina-gateway/1.0",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as upstream:
            return json.load(upstream), None
    except urllib.error.HTTPError as exc:
        try:
            body = json.loads(exc.read().decode("utf-8", errors="replace"))
        except Exception:
            body = {}
        return None, brave_error(exc.code, body, operation)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return None, response(
            "network_error",
            f"brave_{operation}",
            f"Brave {operation} could not be reached through the VPS VPN route: {type(exc).__name__}: {exc}",
        )
    except (json.JSONDecodeError, ValueError) as exc:
        return None, response("provider_error", f"brave_{operation}", f"Brave returned invalid JSON: {exc}")


def freshness_value(value: Any) -> str:
    value = str(value or "").strip()
    return value if not value or FRESHNESS_RE.fullmatch(value) else ""


def brave_search(body: dict[str, Any]) -> dict[str, Any]:
    query = str(body.get("query") or "").strip()
    if not query:
        return response("invalid_request", "brave_web_search", "query is required")
    count = max(1, min(20, int(body.get("count") or 10)))
    payload: dict[str, Any] = {
        "q": query[:600],
        "count": count,
        "country": BRAVE_COUNTRY,
        "search_lang": BRAVE_SEARCH_LANG,
        "ui_lang": BRAVE_UI_LANG,
        "safesearch": "moderate",
        "extra_snippets": bool(body.get("extra_snippets", True)),
    }
    kind = str(body.get("kind") or "web").strip().lower()
    filters = {"web": None, "news": None, "videos": None, "discussions": ["discussions", "query"]}
    if kind not in filters:
        return response("invalid_request", "brave_web_search", "kind must be web, news, videos, or discussions")
    if filters[kind]:
        payload["result_filter"] = filters[kind]
    if kind == "videos":
        payload.pop("extra_snippets", None)
    freshness = freshness_value(body.get("freshness"))
    if body.get("freshness") and not freshness:
        return response("invalid_request", "brave_web_search", "freshness must be pd, pw, pm, py, or YYYY-MM-DDtoYYYY-MM-DD")
    if freshness:
        payload["freshness"] = freshness
    endpoint = {"news": BRAVE_NEWS, "videos": BRAVE_VIDEOS}.get(kind, BRAVE_SEARCH)
    operation = f"{kind}_search" if kind != "web" else "web_search"
    data, error = request_json(endpoint, payload, operation)
    if error:
        return error
    web = ((data or {}).get("web") or {}).get("results") or []
    results = []
    for item in web:
        if not item.get("url"):
            continue
        results.append(
            {
                "title": item.get("title") or item["url"],
                "url": item["url"],
                "snippet": item.get("description") or "",
                "extra_snippets": item.get("extra_snippets") or [],
                "age": item.get("age") or item.get("page_age") or "",
            }
        )
    typed_results: dict[str, Any] = {}
    if kind in {"news", "videos"}:
        vertical = (data or {}).get("results") or ((data or {}).get(kind) or {}).get("results") or []
        cleaned_vertical = []
        for item in vertical[:20]:
            if not isinstance(item, dict):
                continue
            cleaned_vertical.append(
                {
                    "title": item.get("title") or item.get("url") or kind,
                    "url": item.get("url") or "",
                    "snippet": item.get("description") or "",
                    "age": item.get("age") or item.get("page_age") or "",
                }
            )
        if cleaned_vertical:
            typed_results[kind] = cleaned_vertical
    for result_type in ("news", "videos", "discussions"):
        if result_type == kind and result_type in typed_results:
            continue
        items = ((data or {}).get(result_type) or {}).get("results") or []
        cleaned = []
        for item in items[:10]:
            if not isinstance(item, dict):
                continue
            cleaned.append(
                {
                    "title": item.get("title") or item.get("url") or result_type,
                    "url": item.get("url") or "",
                    "snippet": item.get("description") or "",
                    "age": item.get("age") or item.get("page_age") or "",
                }
            )
        if cleaned:
            typed_results[result_type] = cleaned
    faq_items = ((data or {}).get("faq") or {}).get("results") or []
    if faq_items:
        typed_results["faq"] = [
            {
                "question": item.get("question") or item.get("title") or "",
                "answer": item.get("answer") or "",
                "title": item.get("title") or "",
                "url": item.get("url") or "",
            }
            for item in faq_items[:10]
            if isinstance(item, dict)
        ]
    infobox = (data or {}).get("infobox")
    if isinstance(infobox, dict):
        typed_results["infobox"] = infobox
    query_meta = (data or {}).get("query") or {}
    if not results and not typed_results:
        return response(
            "no_results",
            f"brave_{operation}",
            f"Brave {kind} search completed successfully but returned zero results",
            query=query,
            kind=kind,
            locale={"country": BRAVE_COUNTRY, "search_lang": BRAVE_SEARCH_LANG, "ui_lang": BRAVE_UI_LANG},
            altered_query=query_meta.get("altered") or "",
            results=[],
            typed_results={},
        )
    return response(
        "ok",
        f"brave_{operation}",
        f"Brave returned {len(results)} web results and {len(typed_results)} additional result sections",
        query=query,
        kind=kind,
        locale={"country": BRAVE_COUNTRY, "search_lang": BRAVE_SEARCH_LANG, "ui_lang": BRAVE_UI_LANG},
        altered_query=query_meta.get("altered") or "",
        results=results,
        typed_results=typed_results,
    )


def bounded_text(value: Any, maximum: int) -> str:
    value = str(value or "").strip()
    return value[:maximum]


def jina_read(url: str, options: dict[str, Any] | None = None) -> dict[str, Any]:
    safe, reason = public_url(url)
    if not safe:
        return response("unsafe_url", "self_hosted_jina", reason, url=url)
    options = options or {}
    try:
        max_chars = max(2_000, min(MAX_LIBRARY_CHARS, int(options.get("max_chars") or MAX_PAGE_CHARS)))
        timeout = max(5, min(180, int(options.get("timeout") or 45)))
    except (TypeError, ValueError):
        return response("invalid_request", "self_hosted_jina", "max_chars and timeout must be integers", url=url)
    engine = str(options.get("engine") or "auto").strip().lower()
    if engine not in {"auto", "browser", "curl"}:
        return response("invalid_request", "self_hosted_jina", "engine must be auto, browser, or curl", url=url)
    output = str(options.get("output") or "content").strip().lower()
    if output not in {"content", "markdown", "text", "frontmatter", "markdown+frontmatter", "html"}:
        return response("invalid_request", "self_hosted_jina", "unsupported output format", url=url)
    target = f"{JINA_BASE}/{url}"
    headers = {
        "Accept": "text/plain, text/markdown;q=0.9, */*;q=0.1",
        # Jina's documented browser-locale control prevents the Sweden or
        # Switzerland VPN exit from changing the presentation language.
        "X-Locale": JINA_LOCALE,
        "Accept-Language": "en-GB,en;q=0.9",
        "X-No-Cache": "true" if bool(options.get("no_cache", True)) else "false",
        "X-Timeout": str(timeout),
        "X-Engine": engine,
        "X-Respond-With": output,
        "User-Agent": "owui-brave-jina-gateway/1.0",
    }
    header_options = {
        "target_selector": "X-Target-Selector",
        "wait_for_selector": "X-Wait-For-Selector",
        "remove_selector": "X-Remove-Selector",
    }
    for option_name, header_name in header_options.items():
        value = bounded_text(options.get(option_name), 500)
        if value:
            headers[header_name] = value
    req = urllib.request.Request(
        target,
        headers=headers,
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout + 20) as upstream:
            text = upstream.read(max_chars * 4).decode("utf-8", errors="replace").strip()
    except urllib.error.HTTPError as exc:
        return response("reader_error", "self_hosted_jina", f"Self-hosted Jina returned HTTP {exc.code}", url=url, http_status=exc.code)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return response("reader_error", "self_hosted_jina", f"Self-hosted Jina failed: {type(exc).__name__}: {exc}", url=url)
    if len(text) <= 200:
        return response("empty_page", "self_hosted_jina", "Self-hosted Jina returned an empty or near-empty page", url=url)
    marker = blocked_marker(text)
    if marker:
        return response("blocked", "self_hosted_jina", f"Self-hosted Jina received a bot wall ({marker})", url=url)
    return response(
        "ok",
        "self_hosted_jina",
        "Self-hosted Jina returned page content",
        url=url,
        locale=JINA_LOCALE,
        engine=engine,
        output=output,
        content=text[:max_chars],
        content_chars=min(len(text), max_chars),
        truncated=len(text) > max_chars,
    )


def context_sources(data: dict[str, Any]) -> tuple[list[dict[str, Any]], list[str]]:
    generic = (data.get("grounding") or {}).get("generic") or []
    source_meta = data.get("sources") or {}
    rendered: list[dict[str, Any]] = []
    urls: list[str] = []
    for item in generic:
        url = str(item.get("url") or "")
        if not url:
            continue
        meta = source_meta.get(url) or {}
        urls.append(url)
        rendered.append(
            {
                "title": item.get("title") or meta.get("title") or url,
                "url": url,
                "snippets": [str(value).strip() for value in (item.get("snippets") or []) if str(value).strip()],
                "site_name": meta.get("site_name") or meta.get("hostname") or "",
                "description": meta.get("description") or "",
                "age": meta.get("age") or [],
            }
        )
    return rendered, urls


def brave_research(body: dict[str, Any]) -> dict[str, Any]:
    query = str(body.get("query") or "").strip()
    if not query:
        return response("invalid_request", "brave_llm_context+self_hosted_jina", "query is required")
    depth_name = str(body.get("depth") or "standard").strip().lower()
    if depth_name not in DEPTHS:
        return response("invalid_request", "brave_llm_context+self_hosted_jina", "depth must be quick, standard, or deep")
    depth = DEPTHS[depth_name]
    payload: dict[str, Any] = {
        "q": query[:600],
        "country": BRAVE_COUNTRY,
        "search_lang": BRAVE_SEARCH_LANG,
        "count": 20,
        "safesearch": "moderate",
        "maximum_number_of_urls": depth["urls"],
        "maximum_number_of_tokens": depth["tokens"],
        "maximum_number_of_tokens_per_url": 4096,
        "context_threshold_mode": "balanced",
        "enable_source_metadata": True,
    }
    freshness = freshness_value(body.get("freshness"))
    if body.get("freshness") and not freshness:
        return response("invalid_request", "brave_llm_context+self_hosted_jina", "freshness must be pd, pw, pm, py, or YYYY-MM-DDtoYYYY-MM-DD")
    if freshness:
        payload["freshness"] = freshness
    data, error = request_json(BRAVE_CONTEXT, payload, "llm_context")
    if error:
        return error
    context, urls = context_sources(data or {})
    if not context:
        return response(
            "no_results",
            "brave_llm_context",
            "Brave LLM Context completed successfully but returned zero grounding sources",
            query=query,
            locale={"country": BRAVE_COUNTRY, "search_lang": BRAVE_SEARCH_LANG},
            depth=depth_name,
            context=[],
            pages=[],
        )

    page_urls = urls[: depth["pages"]]
    pages: list[dict[str, Any]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(page_urls))) as pool:
        future_map = {pool.submit(jina_read, url): (index, url) for index, url in enumerate(page_urls)}
        ordered: list[tuple[int, dict[str, Any]]] = []
        for future in concurrent.futures.as_completed(future_map):
            index, url = future_map[future]
            try:
                item = future.result()
            except Exception as exc:
                item = response("reader_error", "self_hosted_jina", f"Unexpected Jina worker failure: {type(exc).__name__}: {exc}", url=url)
            ordered.append((index, item))
        pages = [item for _, item in sorted(ordered, key=lambda pair: pair[0])]

    total = 0
    for page in pages:
        content = str(page.get("content") or "")
        allowance = max(0, MAX_TOTAL_PAGE_CHARS - total)
        page["content"] = content[:allowance]
        total += len(page["content"])
        if len(content) > allowance:
            page["truncated"] = True
    failed = sum(1 for page in pages if page.get("status") != "ok")
    return response(
        "partial" if failed else "ok",
        "brave_llm_context+self_hosted_jina",
        f"Brave returned {len(context)} grounding sources; Jina read {len(pages) - failed}/{len(pages)} selected pages",
        query=query,
        locale={"country": BRAVE_COUNTRY, "search_lang": BRAVE_SEARCH_LANG, "jina_locale": JINA_LOCALE},
        depth=depth_name,
        context=context,
        pages=pages,
    )


class Handler(BaseHTTPRequestHandler):
    server_version = "BraveJinaGateway/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        # Intentionally no request bodies or query text in logs.
        print(f"{self.client_address[0]} {self.command} {self.path} " + (fmt % args), flush=True)

    def send_json(self, code: int, payload: dict[str, Any]) -> None:
        encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_json(
                200,
                response(
                    "ok",
                    "gateway",
                    "gateway is ready",
                    brave_configured=bool(os.environ.get("BRAVE_API_KEY", "").strip()),
                    locale_policy={
                        "brave_country": BRAVE_COUNTRY,
                        "brave_search_lang": BRAVE_SEARCH_LANG,
                        "brave_ui_lang": BRAVE_UI_LANG,
                        "jina_locale": JINA_LOCALE,
                    },
                ),
            )
            return
        self.send_json(404, response("not_found", "gateway", "unknown endpoint"))

    def do_POST(self) -> None:
        if self.path not in {"/search", "/research", "/read-url"}:
            self.send_json(404, response("not_found", "gateway", "unknown endpoint"))
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_REQUEST_BYTES:
            self.send_json(413, response("invalid_request", "gateway", "request body is empty or too large"))
            return
        try:
            body = json.loads(self.rfile.read(length))
            if not isinstance(body, dict):
                raise ValueError("JSON body must be an object")
            if self.path == "/search":
                result = brave_search(body)
            elif self.path == "/research":
                result = brave_research(body)
            else:
                result = jina_read(str(body.get("url") or "").strip(), body.get("options"))
            self.send_json(200, result)
        except (json.JSONDecodeError, UnicodeDecodeError, ValueError) as exc:
            self.send_json(400, response("invalid_request", "gateway", f"invalid JSON request: {exc}"))
        except Exception as exc:
            self.send_json(500, response("gateway_error", "gateway", f"unexpected gateway failure: {type(exc).__name__}: {exc}"))


if __name__ == "__main__":
    ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler).serve_forever()
