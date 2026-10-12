"""
Real-time Google Calendar push notifications (watch channels).

Google POSTs to WEBHOOK_PUBLIC_URL whenever a watched calendar changes. We
validate the shared token, then run a debounced incremental sync + OWUI grid
push — so the grid updates within seconds instead of waiting for the 5-min poll.

Channel state is kept in a small JSON file (no DB schema change). Channels expire
(~7 days), so a renewal loop re-registers them before they lapse.

OFF by default. Requires:
  - WATCH_ENABLED=true
  - WEBHOOK_PUBLIC_URL=https://<verified-domain>/google/notifications
  - WATCH_TOKEN=<random secret>
  - the domain verified in Google Cloud Console (see the runbook).
The 5-minute poll stays on as a safety net regardless.
"""
from __future__ import annotations

import asyncio
import json
import time
import uuid
from pathlib import Path
from typing import Any

from . import calendar_ops, db, owui_sync
from .config import settings
from .google_client import calendar_service, credentials_available

_refresh_pending = False


def _state_path() -> Path:
    return settings.data_dir / "watch_channels.json"


def _load() -> dict[str, Any]:
    try:
        return json.loads(_state_path().read_text(encoding="utf-8"))
    except Exception:
        return {}


def _save(state: dict[str, Any]) -> None:
    try:
        _state_path().write_text(json.dumps(state, indent=2), encoding="utf-8")
    except Exception as exc:
        db.audit("watch_state_save_error", details={"error": str(exc)})


def _stop_channel(service, ch: dict[str, Any]) -> None:
    try:
        service.channels().stop(
            body={"id": ch.get("channel_id"), "resourceId": ch.get("resource_id")}
        ).execute()
    except Exception:
        pass  # already gone / expired — fine


def start_watch_all() -> dict[str, Any]:
    """(Re)register a watch channel for every selected calendar."""
    if not settings.webhook_public_url:
        return {"error": "WEBHOOK_PUBLIC_URL not set"}
    if not settings.watch_token:
        return {"error": "WATCH_TOKEN not set (needed to validate incoming notifications)"}
    service = calendar_service()
    ids = calendar_ops.selected_calendar_ids(include_readonly=True)
    state = _load()
    started: list[dict[str, Any]] = []
    for cal in ids:
        existing = state.get(cal)
        if existing:
            _stop_channel(service, existing)
        channel_id = "cmc-" + uuid.uuid4().hex
        body = {
            "id": channel_id,
            "type": "web_hook",
            "address": settings.webhook_public_url,
            "token": settings.watch_token,
            "params": {"ttl": str(settings.watch_ttl_seconds)},
        }
        try:
            resp = service.events().watch(calendarId=cal, body=body).execute()
        except Exception as exc:
            started.append({"calendar": cal, "error": str(exc)})
            continue
        exp_ms = resp.get("expiration")
        expiration = int(int(exp_ms) / 1000) if exp_ms else int(time.time()) + settings.watch_ttl_seconds
        state[cal] = {
            "channel_id": resp.get("id", channel_id),
            "resource_id": resp.get("resourceId"),
            "expiration": expiration,
        }
        started.append({"calendar": cal, "expires": expiration})
    _save(state)
    db.audit("watch_start", details={"count": len([s for s in started if "error" not in s])})
    return {"started": started}


def stop_watch_all() -> dict[str, Any]:
    service = calendar_service()
    state = _load()
    n = 0
    for ch in state.values():
        _stop_channel(service, ch)
        n += 1
    _save({})
    db.audit("watch_stop", details={"count": n})
    return {"stopped": n}


def status() -> dict[str, Any]:
    state = _load()
    now = int(time.time())
    return {
        "enabled": settings.watch_enabled,
        "webhook_public_url": settings.webhook_public_url,
        "token_set": bool(settings.watch_token),
        "channels": [
            {"calendar": k, **v, "expires_in_seconds": int(v.get("expiration", 0)) - now}
            for k, v in state.items()
        ],
    }


def renew_due() -> dict[str, Any]:
    """Re-register channels that are within the renew margin of expiring."""
    margin = settings.watch_renew_margin_seconds
    state = _load()
    now = int(time.time())
    due = [k for k, v in state.items() if int(v.get("expiration", 0)) - now < margin]
    if not state or due:
        return start_watch_all()  # simplest + safe: re-watch everything
    return {"renewed": 0}


def _do_refresh() -> None:
    try:
        calendar_ops.incremental_sync()
        if settings.owui_base_url and settings.owui_api_key:
            owui_sync.push_sync()
        db.audit("watch_refresh", details={"ok": True})
    except Exception as exc:
        db.audit("watch_refresh_error", details={"error": str(exc)})


async def trigger_refresh() -> None:
    """Coalesce a burst of notifications into a single sync after a short delay."""
    global _refresh_pending
    if _refresh_pending:
        return
    _refresh_pending = True
    try:
        await asyncio.sleep(max(0, settings.watch_debounce_seconds))
        await asyncio.to_thread(_do_refresh)
    finally:
        _refresh_pending = False


async def renewal_loop() -> None:
    await asyncio.sleep(15)
    # Ensure channels exist on boot.
    try:
        if settings.watch_enabled and credentials_available() and settings.webhook_public_url:
            await asyncio.to_thread(start_watch_all)
    except Exception as exc:
        db.audit("watch_boot_error", details={"error": str(exc)})
    while True:
        try:
            if settings.watch_enabled and credentials_available() and settings.webhook_public_url:
                await asyncio.to_thread(renew_due)
        except Exception as exc:
            db.audit("watch_renewal_error", details={"error": str(exc)})
        await asyncio.sleep(max(settings.watch_renew_check_seconds, 300))
