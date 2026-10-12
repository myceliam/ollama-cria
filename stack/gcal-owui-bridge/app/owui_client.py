from __future__ import annotations

"""Thin client for Open WebUI's built-in Calendar API (/api/v1/calendar).

Auth: an Open WebUI API key sent as `Authorization: Bearer <key>`.
Timestamps in OWUI are nanosecond epoch integers.
"""

from typing import Any

import requests

from .config import settings


class OWUIError(RuntimeError):
    pass


class OWUINotFound(OWUIError):
    """OWUI returned 404 — the event/calendar we had mapped no longer exists.

    Almost always a stale row in owui_map (event deleted in the OWUI UI, or two
    syncs raced). Callers should self-heal rather than treat it as fatal.
    """


class OWUIClient:
    def __init__(self) -> None:
        if not settings.owui_base_url or not settings.owui_api_key:
            raise OWUIError("OWUI_BASE_URL and OWUI_API_KEY must be set to sync into the OWUI calendar.")
        self.base = settings.owui_base_url.rstrip("/")
        self.session = requests.Session()
        self.session.headers.update(
            {
                "Authorization": f"Bearer {settings.owui_api_key}",
                "Content-Type": "application/json",
            }
        )
        self.timeout = settings.owui_request_timeout

    # ---- low level -------------------------------------------------------
    def _url(self, path: str) -> str:
        # NOTE: OWUI mounts the calendar router at /api/v1/calendars (plural).
        return f"{self.base}/api/v1/calendars{path}"

    def _request(self, method: str, path: str, **kwargs: Any) -> Any:
        resp = self.session.request(method, self._url(path), timeout=self.timeout, **kwargs)
        if resp.status_code == 404:
            raise OWUINotFound(f"OWUI {method} {path} -> 404: {resp.text[:200]}")
        if resp.status_code >= 400:
            raise OWUIError(f"OWUI {method} {path} -> {resp.status_code}: {resp.text[:400]}")
        if resp.content:
            try:
                return resp.json()
            except ValueError:
                return resp.text
        return None

    # ---- calendars -------------------------------------------------------
    def list_calendars(self) -> list[dict[str, Any]]:
        result = self._request("GET", "/")
        if result is None:
            return []
        if not isinstance(result, list):
            # Got HTML/app-shell or an unexpected shape -> wrong route or auth.
            snippet = str(result)[:200]
            raise OWUIError(
                "OWUI GET /api/v1/calendars/ did not return a list "
                f"(got {type(result).__name__}). Check OWUI_BASE_URL, the API key, "
                f"and that the calendar feature is enabled. Body starts: {snippet!r}"
            )
        return result

    def ensure_calendar(self, name: str, color: str | None = None) -> str:
        """Return the id of the calendar named `name`, creating it if missing.

        Never targets the virtual Scheduled Tasks calendar.
        """
        for cal in self.list_calendars():
            if cal.get("id") == "__scheduled_tasks__":
                continue
            if (cal.get("name") or "").strip().lower() == name.strip().lower():
                return cal["id"]
        created = self._request("POST", "/create", json={"name": name, "color": color})
        if not created or "id" not in created:
            raise OWUIError(f"Failed to create OWUI calendar '{name}': {created}")
        return created["id"]

    def find_calendar(self, name: str) -> dict[str, Any] | None:
        """Return the raw calendar dict named `name`, or None."""
        for cal in self.list_calendars():
            if cal.get("id") == "__scheduled_tasks__":
                continue
            if (cal.get("name") or "").strip().lower() == name.strip().lower():
                return cal
        return None

    def ensure_calendar_full(self, name: str, color: str | None = None) -> dict[str, Any]:
        """Like ensure_calendar but returns the whole calendar dict.

        Adopts a pre-existing calendar of the same name rather than creating a
        duplicate — that is how the Google "Family" calendar takes over the
        empty hand-made "Family" calendar instead of sitting next to it.
        """
        existing = self.find_calendar(name)
        if existing:
            return existing
        created = self._request("POST", "/create", json={"name": name, "color": color})
        if not created or "id" not in created:
            raise OWUIError(f"Failed to create OWUI calendar '{name}': {created}")
        return created

    def update_calendar(
        self, calendar_id: str, name: str | None = None, color: str | None = None
    ) -> None:
        payload: dict[str, Any] = {}
        if name is not None:
            payload["name"] = name
        if color is not None:
            payload["color"] = color
        if not payload:
            return
        self._request("POST", f"/{calendar_id}/update", json=payload)

    def delete_calendar(self, calendar_id: str) -> None:
        if calendar_id == "__scheduled_tasks__":
            raise OWUIError("Refusing to delete the virtual Scheduled Tasks calendar.")
        self._request("DELETE", f"/{calendar_id}/delete")

    # ---- events ----------------------------------------------------------
    def create_event(self, form: dict[str, Any]) -> str:
        created = self._request("POST", "/events/create", json=form)
        if not created or "id" not in created:
            raise OWUIError(f"Failed to create OWUI event: {created}")
        return created["id"]

    def update_event(self, event_id: str, form: dict[str, Any]) -> None:
        self._request("POST", f"/events/{event_id}/update", json=form)

    def delete_event(self, event_id: str) -> None:
        self._request("DELETE", f"/events/{event_id}/delete")

    def list_events(self, start_iso: str, end_iso: str, calendar_ids: str | None = None) -> list[dict[str, Any]]:
        params: dict[str, str] = {"start": start_iso, "end": end_iso}
        if calendar_ids:
            params["calendar_ids"] = calendar_ids
        return self._request("GET", "/events", params=params) or []

    def health(self) -> dict[str, Any]:
        """Light reachability + auth check."""
        cals = self.list_calendars()
        return {"reachable": True, "calendar_count": len(cals)}
