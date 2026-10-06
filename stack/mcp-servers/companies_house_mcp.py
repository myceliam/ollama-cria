"""Companies House (UK) — stdio MCP server.

Mirrors the native OWUI tool `companies_house` so the same four lookups are
available to MCP clients (Cline / Antigravity IDE), which cannot see OWUI's
native Python tools.

Runs inside the mcpo-core container exactly like jina_reader_mcp.py:
    docker exec -i mcpo-core uv run --with mcp==1.28.0 --with httpx==0.28.1 \
        python /app/mcp-servers/companies_house_mcp.py

AUTH: Companies House uses HTTP Basic with the API key as the USERNAME and an
EMPTY password. That looks wrong but is correct per their docs.

The key is read from CH_API_KEY. It is never logged, never echoed, and never
included in any tool response.
"""

import os
import re
import time
from typing import Any, Dict, List, Optional

import httpx
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("companies_house")

CH_BASE = "https://api.company-information.service.gov.uk"
CH_API_KEY = os.getenv("CH_API_KEY", "").strip()

# 600 requests / 5 minutes = 2/sec sustained. 0.55s keeps us comfortably inside
# that even when a lookup fans out across several officers.
MIN_INTERVAL = float(os.getenv("CH_MIN_INTERVAL", "0.55"))
TIMEOUT = int(os.getenv("CH_TIMEOUT", "30"))
MAX_RESULTS = int(os.getenv("CH_MAX_RESULTS", "25"))
PERSONS_ONLY = os.getenv("CH_PERSONS_ONLY", "true").lower() == "true"

_last_call = 0.0


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #

def _esc(value: Any) -> str:
    s = " ".join(str(value or "").split())
    return s.replace("|", "\\|") or "-"


def _officer_id(link: str) -> str:
    m = re.search(r"/officers/([^/]+)", link or "")
    return m.group(1) if m else ""


def _dob(node: Optional[Dict[str, Any]]) -> str:
    """Companies House publishes month + year only. Full DOB is never exposed."""
    if not node:
        return "-"
    mo, yr = node.get("month"), node.get("year")
    return f"{int(mo):02d}/{yr}" if (mo and yr) else str(yr or "-")


def _duration(start: Optional[str], end: Optional[str]) -> str:
    if not start:
        return "-"
    try:
        s = time.strptime(start, "%Y-%m-%d")
        e = time.strptime(end, "%Y-%m-%d") if end else time.localtime()
    except (ValueError, TypeError):
        return "-"
    months = (e.tm_year - s.tm_year) * 12 + (e.tm_mon - s.tm_mon)
    if months < 0:
        return "-"
    yrs, mos = divmod(months, 12)
    parts = []
    if yrs:
        parts.append(f"{yrs}y")
    if mos or not yrs:
        parts.append(f"{mos}m")
    return " ".join(parts)


async def _get(path: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """One authenticated GET. Returns {'error': str} rather than raising."""
    global _last_call

    if not CH_API_KEY:
        return {"error": "CH_API_KEY is not set in the mcpo-core container environment. "
                         "Add CH_API_KEY to E:\\ai\\ollama\\.env and recreate mcpo-core."}

    gap = time.monotonic() - _last_call
    if gap < MIN_INTERVAL:
        time.sleep(MIN_INTERVAL - gap)
    _last_call = time.monotonic()

    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            r = await client.get(
                f"{CH_BASE}{path}",
                params=params or {},
                auth=(CH_API_KEY, ""),      # key as username, blank password
                headers={"Accept": "application/json"},
            )
    except httpx.HTTPError as exc:
        return {"error": f"Request failed: {exc}"}

    if r.status_code == 401:
        return {"error": "401 Unauthorized — key rejected. Check it is a REST API key "
                         "(not Streaming or Document) and that it is active."}
    if r.status_code == 404:
        return {"error": "404 Not Found — no such officer or company."}
    if r.status_code == 429:
        return {"error": "429 Rate limited — 600 requests / 5 minutes. Wait, or raise CH_MIN_INTERVAL."}
    if r.status_code >= 400:
        return {"error": f"HTTP {r.status_code}: {r.text[:200]}"}

    try:
        return r.json()
    except ValueError:
        return {"error": "Response was not valid JSON."}


# --------------------------------------------------------------------------- #
# tools
# --------------------------------------------------------------------------- #

@mcp.tool()
async def search_officers(name: str) -> str:
    """Find UK company officers (directors, secretaries) by personal name.

    Use this FIRST to obtain an officer_id, then pass it to officer_appointments.
    Companies House officer search is FUZZY and mixes real people with corporate
    officers; natural persons are the ones with a published birth month/year.
    Disambiguate on birth month/year, locality and appointment count — never on
    result position.
    """
    name = (name or "").strip()
    if not name:
        return "**Error:** provide a name to search for."

    data = await _get("/search/officers", {"q": name, "items_per_page": min(MAX_RESULTS, 50)})
    if "error" in data:
        return f"**Companies House error:** {data['error']}"

    items = data.get("items") or []
    if not items:
        return f"No Companies House officers matched **{_esc(name)}**."

    persons = [i for i in items if (i.get("date_of_birth") or {}).get("year")]
    corporate = [i for i in items if not (i.get("date_of_birth") or {}).get("year")]
    shown = persons if PERSONS_ONLY else items

    if not shown:
        return (f"No **natural persons** matched **{_esc(name)}** — only "
                f"{len(corporate)} corporate officer(s) on this page.")

    rows = [
        f"### Companies House officer search: {_esc(name)}",
        "",
        f"Showing **{min(len(shown), MAX_RESULTS)}** of {len(shown)} natural person(s) on this page"
        + (f"; {len(corporate)} corporate officer(s) hidden." if PERSONS_ONLY and corporate else "."),
        "",
        "_Search is fuzzy and reports a very large total_results regardless. Judge by the_",
        "_birth month/year, area and appointment count below, not by result position._",
        "",
        "| Name | Born | Appts | Occupation / description | Area | officer_id |",
        "|---|---|---|---|---|---|",
    ]
    for it in shown[:MAX_RESULTS]:
        rows.append("| {} | {} | {} | {} | {} | `{}` |".format(
            _esc(it.get("title")),
            _dob(it.get("date_of_birth")),
            _esc(it.get("appointment_count")),
            _esc(it.get("description") or it.get("kind")),
            _esc((it.get("address") or {}).get("locality")
                 or (it.get("address_snippet") or "").split(",")[-1]),
            _officer_id((it.get("links") or {}).get("self", "")),
        ))
    rows += [
        "",
        "_Only birth month/year is published — full dates of birth are never exposed._",
        "",
        "**Next:** call `officer_appointments` with the officer_id of the right person.",
        "",
        "⚠️ Companies House lists COMPANY DIRECTORSHIPS only. A post at the MHRA, NICE or a",
        "government department is NOT a directorship and will never appear here. Absence of a",
        "match is meaningful but not conclusive.",
    ]
    return "\n".join(rows)


@mcp.tool()
async def officer_appointments(officer_id: str) -> str:
    """Every filed directorship for one officer, as a chronological timeline.

    Returns company, role, appointed date, resigned date and tenure, oldest first.
    This is the core view for tracing movement between organisations, with dates
    that were legally filed rather than self-reported.
    """
    officer_id = (officer_id or "").strip().strip("`")
    if not officer_id:
        return "**Error:** provide an officer_id (get one from `search_officers`)."

    data = await _get(f"/officers/{officer_id}/appointments", {"items_per_page": 50})
    if "error" in data:
        return f"**Companies House error:** {data['error']}"

    items = data.get("items") or []
    if not items:
        return f"No appointments found for officer `{_esc(officer_id)}`."

    items.sort(key=lambda i: i.get("appointed_on") or "0000-00-00")
    total = data.get("total_results", len(items))
    active = sum(1 for i in items if not i.get("resigned_on"))

    rows = [
        f"### Appointment timeline: {_esc(data.get('name'))}",
        "",
        f"- Born (month/year): **{_dob(data.get('date_of_birth'))}**",
        f"- Total appointments: **{total}**  ({active} current, {len(items) - active} resigned)",
        f"- officer_id: `{_esc(officer_id)}`",
        "",
        "| Appointed | Resigned | Tenure | Role | Company | No. | Status | Occupation |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for it in items[:MAX_RESULTS]:
        appointed, resigned = it.get("appointed_on"), it.get("resigned_on")
        appt = it.get("appointed_to") or {}
        rows.append("| {} | {} | {} | {} | {} | `{}` | {} | {} |".format(
            appointed or "-",
            resigned or "-",
            _duration(appointed, resigned),
            _esc(it.get("officer_role")),
            _esc(appt.get("company_name") or it.get("company_name")),
            _esc(appt.get("company_number") or it.get("company_number")),
            _esc(appt.get("company_status") or it.get("company_status")),
            _esc(it.get("occupation")),
        ))

    if total > 50:
        rows += ["", f"_⚠️ {total} appointments exist but only the first 50 were fetched "
                     "(one API page; this server does not paginate)._"]
    rows += [
        "",
        "_Dates are as filed with Companies House. Blank 'Resigned' means still in post._",
        "_UK-registered companies only — no non-director employment, public-body roles,_",
        "_or overseas entities._",
    ]
    return "\n".join(rows)


@mcp.tool()
async def search_companies(query: str) -> str:
    """Find UK companies by name or number, to obtain a company_number."""
    query = (query or "").strip()
    if not query:
        return "**Error:** provide a company name or number."

    data = await _get("/search/companies", {"q": query, "items_per_page": min(MAX_RESULTS, 50)})
    if "error" in data:
        return f"**Companies House error:** {data['error']}"

    items = data.get("items") or []
    if not items:
        return f"No companies matched **{_esc(query)}**."

    rows = [
        f"### Company search: {_esc(query)}",
        "",
        "| Company | Number | Status | Incorporated | Type | Address |",
        "|---|---|---|---|---|---|",
    ]
    for it in items[:MAX_RESULTS]:
        rows.append("| {} | `{}` | {} | {} | {} | {} |".format(
            _esc(it.get("title")),
            _esc(it.get("company_number")),
            _esc(it.get("company_status")),
            it.get("date_of_creation") or "-",
            _esc(it.get("company_type")),
            _esc(it.get("address_snippet")),
        ))
    rows += ["", "**Next:** call `company_officers` with a company_number."]
    return "\n".join(rows)


@mcp.tool()
async def company_officers(company_number: str) -> str:
    """List every officer of a UK company with appointment and resignation dates.

    Works the opposite direction to officer_appointments: given a company, see who
    joined its board and when, then cross-reference those names elsewhere.
    """
    company_number = (company_number or "").strip().strip("`").upper()
    if not company_number:
        return "**Error:** provide a company_number (get one from `search_companies`)."

    data = await _get(f"/company/{company_number}/officers", {"items_per_page": 50})
    if "error" in data:
        return f"**Companies House error:** {data['error']}"

    items = data.get("items") or []
    if not items:
        return f"No officers listed for company `{_esc(company_number)}`."

    items.sort(key=lambda i: i.get("appointed_on") or "", reverse=True)

    rows = [
        f"### Officers of company `{_esc(company_number)}`",
        "",
        f"- Active: **{data.get('active_count', '?')}**   Resigned: **{data.get('resigned_count', '?')}**",
        "",
        "| Appointed | Resigned | Tenure | Name | Role | Occupation | Nationality | officer_id |",
        "|---|---|---|---|---|---|---|---|",
    ]
    for it in items[:MAX_RESULTS]:
        appointed, resigned = it.get("appointed_on"), it.get("resigned_on")
        oid = _officer_id(((it.get("links") or {}).get("officer") or {}).get("appointments", ""))
        rows.append("| {} | {} | {} | {} | {} | {} | {} | `{}` |".format(
            appointed or "-",
            resigned or "-",
            _duration(appointed, resigned),
            _esc(it.get("name")),
            _esc(it.get("officer_role")),
            _esc(it.get("occupation")),
            _esc(it.get("nationality")),
            oid or "-",
        ))
    rows += ["", "**Next:** take any officer_id above and call `officer_appointments`."]
    return "\n".join(rows)


if __name__ == "__main__":
    mcp.run(transport="stdio")
