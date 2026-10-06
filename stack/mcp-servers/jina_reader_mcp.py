import os
import ipaddress
from urllib.parse import urlparse

import httpx
from mcp.server.fastmcp import FastMCP


mcp = FastMCP("self_hosted_jina_reader")

JINA_READER_BASE_URL = os.getenv("JINA_READER_BASE_URL", "http://jina-reader:3000").rstrip("/")
ALLOW_PRIVATE_FETCH = os.getenv("ALLOW_PRIVATE_FETCH", "false").lower() == "true"
MAX_CHARS = int(os.getenv("JINA_READER_MAX_CHARS", "80000"))


def _validate_url(url: str) -> str:
    parsed = urlparse(url)

    if parsed.scheme not in {"http", "https"}:
        raise ValueError("Only http:// and https:// URLs are allowed.")

    if not parsed.hostname:
        raise ValueError("URL must include a hostname.")

    hostname = parsed.hostname.lower()

    if ALLOW_PRIVATE_FETCH:
        return url

    blocked_hostnames = {
        "localhost",
        "ip6-localhost",
        "ip6-loopback",
        "0.0.0.0",
    }

    if hostname in blocked_hostnames or hostname.endswith(".local"):
        raise ValueError("Private/local hostnames are blocked by default.")

    try:
        ip = ipaddress.ip_address(hostname.strip("[]"))

        if (
            ip.is_private
            or ip.is_loopback
            or ip.is_link_local
            or ip.is_reserved
            or ip.is_multicast
        ):
            raise ValueError("Private, loopback, link-local, reserved, and multicast IPs are blocked by default.")

    except ValueError as exc:
        if "blocked" in str(exc).lower():
            raise

    return url


@mcp.tool()
async def read_url(url: str, timeout_seconds: int = 45) -> str:
    """
    Read a public web URL using the self-hosted Jina Reader container and return LLM-friendly Markdown/text.

    Use this when the user asks to read, summarise, extract, or analyse a specific web page.
    """

    clean_url = _validate_url(url)

    timeout_seconds = max(5, min(timeout_seconds, 90))
    reader_url = f"{JINA_READER_BASE_URL}/{clean_url}"

    async with httpx.AsyncClient(timeout=timeout_seconds, follow_redirects=True) as client:
        response = await client.get(
            reader_url,
            headers={
                "Accept": "text/markdown,text/plain,*/*",
                "X-Locale": "en-GB",
                "Accept-Language": "en-GB,en;q=0.9",
                "User-Agent": "self-hosted-jina-reader-mcp/1.0",
            },
        )

    response.raise_for_status()

    text = response.text.strip()

    if len(text) > MAX_CHARS:
        return text[:MAX_CHARS] + "\n\n[Output truncated by MCP wrapper.]"

    return text


if __name__ == "__main__":
    mcp.run(transport="stdio")
