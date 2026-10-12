from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any

from googleapiclient.errors import HttpError

from . import db
from .config import settings
from .google_client import calendar_service


def rfc3339_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def default_window() -> tuple[str, str]:
    now = datetime.now(timezone.utc)
    start = now - timedelta(days=settings.default_live_past_days)
    end = now + timedelta(days=settings.default_live_future_days)
    return start.isoformat(), end.isoformat()


def normalise_live_event(calendar_id: str, calendar_summary: str | None, event: dict[str, Any]) -> dict[str, Any]:
    start_obj = event.get("start") or {}
    end_obj = event.get("end") or {}
    return {
        "calendar_id": calendar_id,
        "calendar_summary": calendar_summary,
        "event_id": event.get("id"),
        "title": event.get("summary", "(No title)"),
        "description": event.get("description"),
        "location": event.get("location"),
        "status": event.get("status"),
        "start": start_obj.get("dateTime") or start_obj.get("date"),
        "end": end_obj.get("dateTime") or end_obj.get("date"),
        "all_day": "date" in start_obj and "dateTime" not in start_obj,
        "updated": event.get("updated"),
        "html_link": event.get("htmlLink"),
        "recurring_event_id": event.get("recurringEventId"),
        "organizer": event.get("organizer"),
        "attendees": event.get("attendees", []),
        "raw": event,
    }


def sync_calendar_list() -> list[dict[str, Any]]:
    service = calendar_service()
    calendars: list[dict[str, Any]] = []
    page_token = None
    while True:
        response = service.calendarList().list(pageToken=page_token, maxResults=250).execute()
        for calendar in response.get("items", []):
            db.upsert_calendar(calendar)
            calendars.append(calendar)
        page_token = response.get("nextPageToken")
        if not page_token:
            break
    db.audit("sync_calendar_list", details={"count": len(calendars)})
    return calendars


def selected_calendar_ids(include_readonly: bool = True) -> list[str]:
    calendars = db.list_calendars(selected_only=True)
    ids: list[str] = []
    for calendar in calendars:
        role = calendar.get("access_role")
        if not include_readonly and role not in {"owner", "writer"}:
            continue
        ids.append(calendar["id"])
    return ids


def ensure_calendar_list() -> None:
    if not db.list_calendars():
        sync_calendar_list()


def full_sync_calendar(calendar_id: str) -> dict[str, Any]:
    service = calendar_service()
    db.clear_calendar_events(calendar_id)
    page_token = None
    total = 0
    sync_token = None

    while True:
        response = (
            service.events()
            .list(
                calendarId=calendar_id,
                maxResults=2500,
                showDeleted=True,
                singleEvents=False,
                pageToken=page_token,
            )
            .execute()
        )
        for event in response.get("items", []):
            db.upsert_event(calendar_id, event)
            total += 1
        page_token = response.get("nextPageToken")
        if page_token:
            continue
        sync_token = response.get("nextSyncToken")
        break

    db.set_sync_token(calendar_id, sync_token, full=True)
    db.audit("full_sync", calendar_id=calendar_id, details={"events": total, "has_sync_token": bool(sync_token)})
    return {"calendar_id": calendar_id, "events_synced": total, "has_sync_token": bool(sync_token)}


def full_sync(calendar_ids: list[str] | None = None, include_readonly: bool = True) -> dict[str, Any]:
    ensure_calendar_list()
    ids = calendar_ids or selected_calendar_ids(include_readonly=include_readonly)
    results = []
    for calendar_id in ids:
        try:
            results.append(full_sync_calendar(calendar_id))
        except HttpError as exc:
            db.set_sync_error(calendar_id, str(exc))
            results.append({"calendar_id": calendar_id, "error": str(exc)})
    return {"mode": "full", "calendar_count": len(ids), "results": results}


def incremental_sync_calendar(calendar_id: str, full_sync_if_missing_token: bool = True) -> dict[str, Any]:
    state = db.get_sync_state(calendar_id) or {}
    sync_token = state.get("sync_token")
    if not sync_token:
        if full_sync_if_missing_token:
            result = full_sync_calendar(calendar_id)
            result["mode"] = "full_missing_token"
            return result
        return {"calendar_id": calendar_id, "skipped": True, "reason": "missing_sync_token"}

    service = calendar_service()
    page_token = None
    total = 0
    deleted = 0
    next_sync_token = None

    try:
        while True:
            response = (
                service.events()
                .list(
                    calendarId=calendar_id,
                    maxResults=2500,
                    showDeleted=True,
                    singleEvents=False,
                    syncToken=sync_token,
                    pageToken=page_token,
                )
                .execute()
            )
            for event in response.get("items", []):
                if event.get("status") == "cancelled":
                    deleted += 1
                db.upsert_event(calendar_id, event)
                total += 1
            page_token = response.get("nextPageToken")
            if page_token:
                continue
            next_sync_token = response.get("nextSyncToken")
            break
    except HttpError as exc:
        status = getattr(exc.resp, "status", None)
        if status == 410:
            db.audit("sync_token_expired", calendar_id=calendar_id, details={"error": str(exc)})
            result = full_sync_calendar(calendar_id)
            result["mode"] = "full_after_410"
            return result
        db.set_sync_error(calendar_id, str(exc))
        raise

    db.set_sync_token(calendar_id, next_sync_token or sync_token, full=False)
    db.audit(
        "incremental_sync",
        calendar_id=calendar_id,
        details={"changed_events": total, "deleted_events": deleted, "has_next_sync_token": bool(next_sync_token)},
    )
    return {
        "calendar_id": calendar_id,
        "mode": "incremental",
        "changed_events": total,
        "deleted_events": deleted,
        "has_sync_token": bool(next_sync_token or sync_token),
    }


def incremental_sync(
    calendar_ids: list[str] | None = None,
    include_readonly: bool = True,
    full_sync_if_missing_token: bool = True,
) -> dict[str, Any]:
    ensure_calendar_list()
    ids = calendar_ids or selected_calendar_ids(include_readonly=include_readonly)
    results = []
    for calendar_id in ids:
        try:
            results.append(incremental_sync_calendar(calendar_id, full_sync_if_missing_token))
        except HttpError as exc:
            db.set_sync_error(calendar_id, str(exc))
            results.append({"calendar_id": calendar_id, "error": str(exc)})
    return {"mode": "incremental", "calendar_count": len(ids), "results": results}


def live_events(
    start: str | None = None,
    end: str | None = None,
    calendar_ids: list[str] | None = None,
    query: str | None = None,
    include_all_selected: bool = True,
    include_readonly: bool = True,
) -> list[dict[str, Any]]:
    ensure_calendar_list()
    if not start or not end:
        default_start, default_end = default_window()
        start = start or default_start
        end = end or default_end

    calendars = db.list_calendars(selected_only=True)
    calendar_summary = {calendar["id"]: calendar.get("summary") for calendar in calendars}

    if calendar_ids:
        ids = calendar_ids
    elif include_all_selected:
        ids = selected_calendar_ids(include_readonly=include_readonly)
    else:
        ids = ["primary"]

    service = calendar_service()
    events: list[dict[str, Any]] = []
    for calendar_id in ids:
        page_token = None
        while True:
            kwargs: dict[str, Any] = {
                "calendarId": calendar_id,
                "timeMin": start,
                "timeMax": end,
                "singleEvents": True,
                "orderBy": "startTime",
                "maxResults": 2500,
                "pageToken": page_token,
                "timeZone": settings.default_timezone,
            }
            if query:
                kwargs["q"] = query
            response = service.events().list(**kwargs).execute()
            for event in response.get("items", []):
                events.append(normalise_live_event(calendar_id, calendar_summary.get(calendar_id), event))
            page_token = response.get("nextPageToken")
            if not page_token:
                break

    events.sort(key=lambda item: item.get("start") or "")
    db.audit("live_events", details={"calendar_ids": ids, "start": start, "end": end, "query": query, "count": len(events)})
    return events


def build_event_body(payload: Any, patch: bool = False) -> dict[str, Any]:
    body: dict[str, Any] = {}

    title = getattr(payload, "title", None)
    if title is not None:
        body["summary"] = title

    description = getattr(payload, "description", None)
    if description is not None:
        body["description"] = description

    location = getattr(payload, "location", None)
    if location is not None:
        body["location"] = location

    start = getattr(payload, "start", None)
    end = getattr(payload, "end", None)
    all_day = getattr(payload, "all_day", False)
    timezone_name = getattr(payload, "timezone", settings.default_timezone)

    if start is not None:
        body["start"] = {"date": start} if all_day else {"dateTime": start, "timeZone": timezone_name}
    if end is not None:
        body["end"] = {"date": end} if all_day else {"dateTime": end, "timeZone": timezone_name}

    attendees = getattr(payload, "attendees", None)
    if attendees:
        body["attendees"] = [{"email": email} for email in attendees]

    recurrence = getattr(payload, "recurrence", None)
    if recurrence:
        body["recurrence"] = recurrence

    clear_reminders = getattr(payload, "clear_reminders", False)
    reminder_minutes = getattr(payload, "reminder_minutes", None)
    if clear_reminders:
        body["reminders"] = {"useDefault": True}
    elif reminder_minutes is not None:
        body["reminders"] = {
            "useDefault": False,
            "overrides": [{"method": "popup", "minutes": reminder_minutes}],
        }
    elif not patch:
        body["reminders"] = {"useDefault": True}

    return body


def create_event(payload: Any) -> dict[str, Any]:
    service = calendar_service()
    body = build_event_body(payload)
    event = service.events().insert(calendarId=payload.calendar_id, body=body).execute()
    db.upsert_event(payload.calendar_id, event)
    db.audit("create_event", calendar_id=payload.calendar_id, event_id=event.get("id"), details=body)
    return normalise_live_event(payload.calendar_id, None, event)


def patch_event(payload: Any) -> dict[str, Any]:
    service = calendar_service()
    body = build_event_body(payload, patch=True)
    event = (
        service.events()
        .patch(calendarId=payload.calendar_id, eventId=payload.event_id, body=body)
        .execute()
    )
    db.upsert_event(payload.calendar_id, event)
    db.audit("patch_event", calendar_id=payload.calendar_id, event_id=payload.event_id, details=body)
    return normalise_live_event(payload.calendar_id, None, event)


def get_event(calendar_id: str, event_id: str) -> dict[str, Any]:
    service = calendar_service()
    event = service.events().get(calendarId=calendar_id, eventId=event_id).execute()
    db.upsert_event(calendar_id, event)
    db.audit("get_event", calendar_id=calendar_id, event_id=event_id)
    return normalise_live_event(calendar_id, None, event)


def delete_event(calendar_id: str, event_id: str) -> dict[str, Any]:
    service = calendar_service()
    service.events().delete(calendarId=calendar_id, eventId=event_id).execute()
    db.mark_event_deleted(calendar_id, event_id)
    db.audit("delete_event", calendar_id=calendar_id, event_id=event_id)
    return {"deleted": True, "calendar_id": calendar_id, "event_id": event_id}


def undo_last_create() -> dict[str, Any]:
    """Delete the most recently bridge-created event that hasn't already been undone."""
    entries = db.latest_audit(100)
    already_undone = {e.get("event_id") for e in entries if e.get("action") == "undo_create"}
    for entry in entries:
        if entry.get("action") != "create_event":
            continue
        event_id = entry.get("event_id")
        if not event_id or event_id in already_undone:
            continue
        calendar_id = entry.get("calendar_id") or "primary"
        title = (entry.get("details_json") or {}).get("summary")
        try:
            delete_event(calendar_id, event_id)
        except HttpError as exc:
            status = getattr(exc.resp, "status", None)
            if status in (404, 410):  # already gone
                db.audit("undo_create", calendar_id=calendar_id, event_id=event_id, details={"note": "already_absent"})
                return {"undone": True, "calendar_id": calendar_id, "event_id": event_id, "title": title, "note": "was already removed"}
            raise
        db.audit("undo_create", calendar_id=calendar_id, event_id=event_id, details={"title": title})
        return {"undone": True, "calendar_id": calendar_id, "event_id": event_id, "title": title}
    return {"undone": False, "reason": "No recent event created via the bridge to undo."}


def freebusy(start: str, end: str, calendar_ids: list[str], timezone_name: str) -> dict[str, Any]:
    service = calendar_service()
    body = {
        "timeMin": start,
        "timeMax": end,
        "timeZone": timezone_name,
        "items": [{"id": calendar_id} for calendar_id in calendar_ids],
    }
    response = service.freebusy().query(body=body).execute()
    db.audit("freebusy", details={"calendar_ids": calendar_ids, "start": start, "end": end})
    return response
