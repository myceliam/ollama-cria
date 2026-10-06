from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone
from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, PlainTextResponse
from googleapiclient.errors import HttpError

from . import calendar_ops, db, owui_sync, tasks_ops, watch
from .config import settings
from .owui_client import OWUIClient
from .google_client import (
    SCOPES,
    TASKS_SCOPE,
    client_secret_available,
    complete_oauth_callback,
    credentials_available,
    google_error_to_http,
    granted_scopes,
    make_auth_url,
)
from .schemas import (
    DeleteEventRequest,
    EventCreateRequest,
    EventPatchRequest,
    FreeBusyRequest,
    FullSyncRequest,
    IncrementalSyncRequest,
    SelectCalendarRequest,
)

app = FastAPI(
    title="Google Calendar OWUI Bridge",
    version="1.0.0",
    description=(
        "Open WebUI-ready Google Calendar bridge with live event queries, "
        "safe create/update/delete actions, SQLite caching, and incremental sync."
    ),
)


async def require_api_key(
    x_api_key: str | None = Header(default=None),
    authorization: str | None = Header(default=None),
) -> None:
    if not settings.api_key:
        return
    # Accept the key via X-API-Key OR an Authorization: Bearer <key> header,
    # so Open WebUI's "Bearer" auth type works out of the box.
    token = x_api_key
    if not token and authorization and authorization.lower().startswith("bearer "):
        token = authorization[7:].strip()
    if token != settings.api_key:
        raise HTTPException(
            status_code=401,
            detail="Missing or invalid API key (send X-API-Key or Authorization: Bearer)",
        )


def split_csv(value: str | None) -> list[str] | None:
    if not value:
        return None
    return [item.strip() for item in value.split(",") if item.strip()]


def utc_iso(days_from_now: int = 0) -> str:
    return (datetime.now(timezone.utc) + timedelta(days=days_from_now)).isoformat()


@app.on_event("startup")
async def on_startup() -> None:
    db.init_db()
    if settings.enable_background_sync:
        asyncio.create_task(background_sync_loop())
    if settings.owui_sync_enabled:
        asyncio.create_task(owui_push_loop())
    if settings.watch_enabled:
        asyncio.create_task(watch.renewal_loop())


async def owui_push_loop() -> None:
    # Stagger after the Google cache loop so the first run has fresh data.
    await asyncio.sleep(8)
    while True:
        try:
            if credentials_available() and settings.owui_base_url and settings.owui_api_key:
                await asyncio.to_thread(owui_sync.push_sync)
        except Exception as exc:  # background sync must never crash the API
            db.audit("owui_push_loop_error", details={"error": str(exc)})
        await asyncio.sleep(max(settings.owui_sync_interval_seconds, 60))


async def background_sync_loop() -> None:
    # Give the app a few seconds to start cleanly before first sync attempt.
    await asyncio.sleep(5)
    while True:
        try:
            if credentials_available():
                await asyncio.to_thread(calendar_ops.sync_calendar_list)
                await asyncio.to_thread(calendar_ops.incremental_sync)
        except Exception as exc:  # deliberately broad: background sync must not crash the API
            db.audit("background_sync_error", details={"error": str(exc)})
        await asyncio.sleep(max(settings.sync_interval_seconds, 60))


@app.get("/", response_class=HTMLResponse, include_in_schema=False)
def root() -> str:
    return """
    <html>
      <head><title>Google Calendar OWUI Bridge</title></head>
      <body style="font-family: sans-serif; max-width: 900px; margin: 2rem auto; line-height: 1.5;">
        <h1>Google Calendar OWUI Bridge</h1>
        <p>Use <code>/docs</code> for Swagger, <code>/openapi.json</code> for Open WebUI, and <code>/auth/url</code> to start OAuth.</p>
        <p>Health: <a href="/health">/health</a></p>
      </body>
    </html>
    """


@app.get("/health", tags=["system"])
def health() -> dict[str, Any]:
    return {
        "ok": True,
        "app": settings.app_name,
        "authenticated": credentials_available(),
        "client_secret_present": client_secret_available(),
        "sqlite_path": str(settings.sqlite_path),
        "timezone": settings.default_timezone,
        "background_sync_enabled": settings.enable_background_sync,
        "sync_interval_seconds": settings.sync_interval_seconds,
        "api_key_required": bool(settings.api_key),
    }


@app.get("/auth/status", tags=["auth"], dependencies=[Depends(require_api_key)])
def auth_status() -> dict[str, Any]:
    granted = granted_scopes()
    return {
        "authenticated": credentials_available(),
        "client_secret_present": client_secret_available(),
        "client_secret_path": str(settings.google_client_secret_file),
        "token_path": str(settings.google_token_file),
        "redirect_uri": settings.oauth_redirect_uri,
        "requested_scopes": SCOPES,
        "granted_scopes": granted,
        "missing_scopes": [s for s in SCOPES if s not in granted],
        "tasks_scope_granted": TASKS_SCOPE in granted,
    }


@app.get("/auth/url", tags=["auth"], dependencies=[Depends(require_api_key)])
def auth_url() -> dict[str, str]:
    return make_auth_url()


@app.get("/auth/callback", tags=["auth"], include_in_schema=False)
def auth_callback(code: str, state: str | None = None) -> HTMLResponse:
    result = complete_oauth_callback(code=code, state=state)
    return HTMLResponse(
        f"""
        <html><body style="font-family: sans-serif; max-width: 800px; margin: 2rem auto;">
        <h1>Google Calendar authorised ✅</h1>
        <p>You can close this tab and return to Open WebUI.</p>
        <pre>{result}</pre>
        </body></html>
        """
    )


@app.post("/calendars/refresh", tags=["calendars"], dependencies=[Depends(require_api_key)])
def refresh_calendars() -> dict[str, Any]:
    try:
        calendars = calendar_ops.sync_calendar_list()
        return {"count": len(calendars), "calendars": calendars}
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.get("/calendars", tags=["calendars"], dependencies=[Depends(require_api_key)])
def get_calendars(selected_only: bool = False) -> dict[str, Any]:
    calendars = db.list_calendars(selected_only=selected_only)
    return {"count": len(calendars), "calendars": calendars}


@app.post("/calendars/select", tags=["calendars"], dependencies=[Depends(require_api_key)])
def select_calendar(payload: SelectCalendarRequest) -> dict[str, Any]:
    db.set_calendar_selected(payload.calendar_id, payload.selected)
    db.audit("select_calendar", calendar_id=payload.calendar_id, details={"selected": payload.selected})
    return {"calendar_id": payload.calendar_id, "selected": payload.selected}


@app.post("/sync/full", tags=["sync"], dependencies=[Depends(require_api_key)])
def full_sync(payload: FullSyncRequest) -> dict[str, Any]:
    try:
        return calendar_ops.full_sync(payload.calendar_ids, include_readonly=payload.include_readonly)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.post("/sync/incremental", tags=["sync"], dependencies=[Depends(require_api_key)])
def incremental_sync(payload: IncrementalSyncRequest) -> dict[str, Any]:
    try:
        return calendar_ops.incremental_sync(
            payload.calendar_ids,
            include_readonly=payload.include_readonly,
            full_sync_if_missing_token=payload.full_sync_if_missing_token,
        )
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.get("/sync/status", tags=["sync"], dependencies=[Depends(require_api_key)])
def sync_status() -> dict[str, Any]:
    state = db.list_sync_state()
    return {"count": len(state), "sync_state": state}


@app.get("/events/live", tags=["events"], dependencies=[Depends(require_api_key)])
def get_live_events(
    start: str | None = Query(default=None, description="RFC3339 start. Defaults to now."),
    end: str | None = Query(default=None, description="RFC3339 end. Defaults to now + DEFAULT_LIVE_FUTURE_DAYS."),
    calendar_ids: str | None = Query(default=None, description="Comma-separated calendar IDs. Omit for all selected calendars."),
    query: str | None = Query(default=None, description="Google Calendar full-text query."),
    include_all_selected: bool = True,
    include_readonly: bool = True,
) -> dict[str, Any]:
    try:
        events = calendar_ops.live_events(
            start=start,
            end=end,
            calendar_ids=split_csv(calendar_ids),
            query=query,
            include_all_selected=include_all_selected,
            include_readonly=include_readonly,
        )
        return {"source": "google_calendar_live", "count": len(events), "events": events}
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.get("/events/next", tags=["events"], dependencies=[Depends(require_api_key)])
def get_next_events(
    days: int = Query(default=7, ge=1, le=370, description="Days ahead to look (1-370). Defaults to 7."),
    query: str | None = Query(default=None, description="Optional text filter."),
) -> dict[str, Any]:
    """Foolproof read: upcoming events from now to now+days across all selected
    calendars. No timestamps for the model to compute — ideal for small models, and
    always bounded so it can never overflow. Prefer this for 'what's coming up?'."""
    start = utc_iso(0)
    end = utc_iso(days)
    try:
        events = calendar_ops.live_events(start=start, end=end, query=query)
        return {"source": "google_calendar_live", "window_days": days, "count": len(events), "events": events}
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.get("/events/cache/search", tags=["events"], dependencies=[Depends(require_api_key)])
def search_cache(
    q: str | None = None,
    start: str | None = None,
    end: str | None = None,
    include_deleted: bool = False,
    limit: int = Query(default=100, ge=1, le=500),
) -> dict[str, Any]:
    events = db.search_cached_events(q=q, start=start, end=end, include_deleted=include_deleted, limit=limit)
    return {"source": "sqlite_cache", "count": len(events), "events": events}


@app.post("/events/create", tags=["events"], dependencies=[Depends(require_api_key)])
def create_event(payload: EventCreateRequest) -> dict[str, Any]:
    try:
        return calendar_ops.create_event(payload)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.post("/events/update", tags=["events"], dependencies=[Depends(require_api_key)])
def update_event(payload: EventPatchRequest) -> dict[str, Any]:
    try:
        return calendar_ops.patch_event(payload)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.get("/events/get", tags=["events"], dependencies=[Depends(require_api_key)])
def get_event(calendar_id: str, event_id: str) -> dict[str, Any]:
    try:
        return calendar_ops.get_event(calendar_id, event_id)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.get("/events/delete_preview", tags=["events"], dependencies=[Depends(require_api_key)])
def delete_preview(
    query: str,
    start: str | None = None,
    end: str | None = None,
    calendar_ids: str | None = None,
) -> dict[str, Any]:
    if not start:
        start = utc_iso(-30)
    if not end:
        end = utc_iso(365)
    try:
        events = calendar_ops.live_events(
            start=start,
            end=end,
            calendar_ids=split_csv(calendar_ids),
            query=query,
            include_all_selected=True,
            include_readonly=False,
        )
        return {
            "instruction": "Review matches carefully. To delete, call /events/delete with calendar_id, event_id, and confirmed=true.",
            "count": len(events),
            "events": events,
        }
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.post("/events/delete", tags=["events"], dependencies=[Depends(require_api_key)])
def delete_event(payload: DeleteEventRequest) -> dict[str, Any]:
    if not payload.confirmed:
        raise HTTPException(
            status_code=400,
            detail={
                "error": "confirmation_required",
                "message": "Deletion requires confirmed=true after reviewing the exact event_id and calendar_id.",
            },
        )
    try:
        return calendar_ops.delete_event(payload.calendar_id, payload.event_id)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.post("/events/undo", tags=["events"], dependencies=[Depends(require_api_key)])
def undo_last_event() -> dict[str, Any]:
    """Undo (delete) the most recent event created via this bridge."""
    try:
        return calendar_ops.undo_last_create()
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.post("/freebusy", tags=["freebusy"], dependencies=[Depends(require_api_key)])
def freebusy(payload: FreeBusyRequest) -> dict[str, Any]:
    try:
        return calendar_ops.freebusy(payload.start, payload.end, payload.calendar_ids, payload.timezone)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.post("/owui/sync", tags=["owui"], dependencies=[Depends(require_api_key)])
def owui_sync_now(dry_run: bool = Query(default=False, description="Preview counts without writing to OWUI.")) -> dict[str, Any]:
    """Push Google events into Open WebUI's built-in Calendar grid."""
    return owui_sync.push_sync(dry_run=dry_run)


@app.post("/owui/remap", tags=["owui"], dependencies=[Depends(require_api_key)])
def owui_remap(dry_run: bool = Query(default=False, description="Preview without moving anything.")) -> dict[str, Any]:
    """Relocate already-synced events into their correct coloured calendar.

    Use after switching on per-calendar mode, or after recolouring a calendar
    in Google. Covers events outside the rolling sync window, which the normal
    push never revisits.
    """
    return owui_sync.remap_calendars(dry_run=dry_run)


@app.get("/owui/status", tags=["owui"], dependencies=[Depends(require_api_key)])
def owui_status() -> dict[str, Any]:
    configured = bool(settings.owui_base_url and settings.owui_api_key)
    out: dict[str, Any] = {
        "configured": configured,
        "sync_enabled": settings.owui_sync_enabled,
        "mode": "per-calendar" if settings.owui_per_calendar else "single-calendar",
        "colour_events": settings.owui_colour_events,
        "calendar_name_template": settings.owui_calendar_name_template,
        "legacy_calendar_name": settings.owui_target_calendar_name,
        "tasks_sync_enabled": settings.tasks_sync_enabled,
        "tasks_scope_granted": TASKS_SCOPE in granted_scopes(),
        "mapped_events": db.count_owui_map(),
        "interval_seconds": settings.owui_sync_interval_seconds,
        "window_days": {"past": settings.owui_sync_past_days, "future": settings.owui_sync_future_days},
        "base_url": settings.owui_base_url,
    }
    if configured:
        try:
            client = OWUIClient()
            out["owui"] = client.health()
            out["owui_calendars"] = [
                {"id": c.get("id"), "name": c.get("name"), "color": c.get("color")}
                for c in client.list_calendars()
            ]
        except Exception as exc:
            out["owui_error"] = str(exc)
    return out


@app.get("/tasks/lists", tags=["tasks"], dependencies=[Depends(require_api_key)])
def tasks_lists() -> dict[str, Any]:
    """Google Tasks lists. Needs the tasks.readonly scope + Tasks API enabled."""
    lists = tasks_ops.list_task_lists()
    return {
        "count": len(lists),
        "lists": [{"id": tl.get("id"), "title": tl.get("title")} for tl in lists],
    }


@app.get("/tasks/due", tags=["tasks"], dependencies=[Depends(require_api_key)])
def tasks_due(
    days: int = Query(default=7, ge=1, le=370, description="Look-ahead window in days."),
    past_days: int = Query(default=0, ge=0, le=370, description="Look-back window in days."),
) -> dict[str, Any]:
    """Foolproof bounded read of upcoming Google Tasks (small-model safe)."""
    tasks = tasks_ops.live_tasks(past_days=past_days, future_days=days)
    tasks.sort(key=lambda t: t.get("start") or "")
    return {"count": len(tasks), "window_days": {"past": past_days, "future": days}, "tasks": tasks}


@app.post("/google/notifications", tags=["realtime"], include_in_schema=False)
async def google_notifications(request: Request) -> dict[str, Any]:
    """Google Calendar push webhook. No API key (Google can't send one) — validated
    via the shared channel token. Returns 200 instantly; refresh runs in background."""
    token = request.headers.get("X-Goog-Channel-Token")
    if settings.watch_token and token != settings.watch_token:
        raise HTTPException(status_code=403, detail="invalid channel token")
    state = request.headers.get("X-Goog-Resource-State")
    db.audit("watch_notification", details={"state": state, "channel": request.headers.get("X-Goog-Channel-ID")})
    if state and state != "sync":  # 'sync' is the initial handshake — ignore it
        asyncio.create_task(watch.trigger_refresh())
    return {"ok": True}


@app.post("/google/watch/start", tags=["realtime"], dependencies=[Depends(require_api_key)])
def watch_start() -> dict[str, Any]:
    """Manually (re)register Google push channels for all selected calendars."""
    return watch.start_watch_all()


@app.post("/google/watch/stop", tags=["realtime"], dependencies=[Depends(require_api_key)])
def watch_stop() -> dict[str, Any]:
    """Stop all Google push channels (falls back to the 5-min poll)."""
    return watch.stop_watch_all()


@app.get("/google/watch/status", tags=["realtime"], dependencies=[Depends(require_api_key)])
def watch_status() -> dict[str, Any]:
    return watch.status()


@app.get("/audit", tags=["system"], dependencies=[Depends(require_api_key)])
def audit(limit: int = Query(default=50, ge=1, le=200)) -> dict[str, Any]:
    entries = db.latest_audit(limit=limit)
    return {"count": len(entries), "entries": entries}


@app.get("/robots.txt", include_in_schema=False)
def robots() -> PlainTextResponse:
    return PlainTextResponse("User-agent: *\nDisallow: /\n")
