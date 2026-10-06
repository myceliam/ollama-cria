"""Expose the unchanged SearXNG tool catalog with a fresh VPS session per call.

Listing tools never needs the VPS. This prevents a remote outage at mcpo boot
from cancelling other MCP servers, and avoids stale sessions after a VPS restart.
All search and page fetching takes place in the protected VPS containers.
"""
import asyncio
import json
import os
from pathlib import Path

from mcp import ClientSession, types
from mcp.client.streamable_http import streamablehttp_client
from mcp.server import Server
from mcp.server.stdio import stdio_server

URL = os.getenv("VPS_SEARCH_MCP_URL", "http://searxng-mcp:3055/mcp")
CATALOG = [types.Tool(**item) for item in json.loads(Path(__file__).with_name("web_search_vps_tools.json").read_text())]
NAMES = {tool.name for tool in CATALOG}
server = Server("searxng_vps_reconnecting")


@server.list_tools()
async def list_tools():
    return CATALOG


@server.call_tool()
async def call_tool(name: str, arguments: dict):
    if name not in NAMES:
        raise ValueError("Unknown search tool")
    try:
        async with asyncio.timeout(90):
            async with streamablehttp_client(URL, timeout=15, sse_read_timeout=75) as (read, write, _):
                async with ClientSession(read, write) as session:
                    await session.initialize()
                    result = await session.call_tool(name, arguments)
                    if result.isError:
                        raise RuntimeError("; ".join(getattr(c, "text", "") for c in result.content))
                    return result.content
    except Exception as exc:
        # No retries against local engines, public readers, or another endpoint.
        #
        # 2026-09-19: surface the underlying cause. The old message said only
        # "VPS search unavailable (ExceptionGroup)", which is actively
        # misleading - it reads as "the VPS is down" when the real answer was
        # often "the target site returned 403". That cost a full debugging
        # session chasing infrastructure that was working perfectly.
        # ExceptionGroup hides its members behind an unhelpful str(), so unwrap.
        def _causes(e, depth=0):
            if depth > 3:
                return []
            subs = getattr(e, "exceptions", None)
            if subs:
                out = []
                for sub in subs:
                    out.extend(_causes(sub, depth + 1))
                return out
            text = str(e).strip()
            return [f"{type(e).__name__}: {text}" if text else type(e).__name__]

        detail = "; ".join(dict.fromkeys(_causes(exc))) or type(exc).__name__
        raise RuntimeError(
            f"VPS search call failed. Underlying cause: {detail}. "
            "No direct or browser fallback was used. If this is an HTTP 403 or "
            "a bot wall, the site is refusing the protected exit."
        ) from exc


async def main():
    async with stdio_server() as (read, write):
        await server.run(read, write, server.create_initialization_options())


if __name__ == "__main__":
    asyncio.run(main())
