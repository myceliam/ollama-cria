# SPDX-License-Identifier: AGPL-3.0-or-later
"""SearXNG Brave API engine with explicit GB geography and env-only key.

The stock engine does not send country or language fields.  This local patch
keeps results British even though network egress is a Mullvad endpoint, and it
loads BRAVE_API_KEY from the container environment so settings.yml contains no
credential.
"""

import os
import typing as t
from urllib.parse import urlencode

from dateutil import parser
from searx.exceptions import SearxEngineAPIException
from searx.result_types import EngineResults

if t.TYPE_CHECKING:
    from searx.extended_types import SXNG_Response
    from searx.search.processors import OnlineParams

about = {
    "website": "https://api.search.brave.com/",
    "wikidata_id": None,
    "official_api_documentation": "https://api-dashboard.search.brave.com/documentation",
    "use_official_api": True,
    "require_api_key": True,
    "results": "JSON",
}

api_key: str = ""
categories = ["general", "web"]
paging = True
safesearch = True
time_range_support = True
results_per_page: int = 20
country: str = ""
search_lang: str = ""
ui_lang: str = ""
base_url = "https://api.search.brave.com/res/v1/web/search"
time_range_map = {"day": "past_day", "week": "past_week", "month": "past_month", "year": "past_year"}


def init(_):
    """Load the key from the VPS environment when YAML intentionally omits it."""
    global api_key
    if not api_key:
        api_key = os.environ.get("BRAVE_API_KEY", "").strip()
    if not api_key:
        raise SearxEngineAPIException("No Brave API key provided in BRAVE_API_KEY")


def request(query: str, params: "OnlineParams") -> None:
    search_args: dict[str, str | int | None] = {
        "q": query,
        "count": results_per_page,
        "offset": (params["pageno"] - 1) * results_per_page,
    }
    if country:
        search_args["country"] = country
    if search_lang:
        search_args["search_lang"] = search_lang
    if ui_lang:
        search_args["ui_lang"] = ui_lang
    if params["time_range"]:
        search_args["time_range"] = time_range_map.get(params["time_range"])
    if params["safesearch"]:
        search_args["safesearch"] = "strict"
    params["url"] = f"{base_url}?{urlencode(search_args)}"
    params["headers"]["X-Subscription-Token"] = api_key


def _extract_published_date(published_date_raw: str):
    if not published_date_raw:
        return None
    try:
        return parser.parse(published_date_raw)
    except parser.ParserError:
        return None


def response(resp: "SXNG_Response") -> EngineResults:
    res = EngineResults()
    data = resp.json()
    for result in data.get("web", {}).get("results", []):
        res.add(
            res.types.MainResult(
                url=result["url"],
                title=result["title"],
                content=result.get("description", ""),
                publishedDate=_extract_published_date(result.get("age")),
                thumbnail=result.get("thumbnail", {}).get("src"),
            ),
        )
    return res
