from __future__ import annotations

"""One-way sync: Google Calendar + Google Tasks -> Open WebUI's Calendar grid.

Strategy (deliberately simple, to avoid two-master conflict hell):
- Google stays the source of truth.
- We pull EXPANDED Google instances for a rolling window (live_events), plus
  Google Tasks due in the same window (live_tasks).
- Each Google calendar gets its OWN OpenWebUI calendar, coloured with that
  calendar's own Google backgroundColor. Each Google Tasks list likewise, with
  a colour from a rotating palette (Tasks has no colour of its own).
- A local map table (owui_map) keys gcal instance id -> owui event id, so
  re-runs UPDATE in place and never duplicate.
- Events that vanish from Google within the window are deleted from OWUI.

OWUI timestamps are nanosecond epoch integers.
"""

import hashlib
import json
import threading
from datetime import date, datetime, timedelta, timezone
from typing import Any
from zoneinfo import ZoneInfo

from . import calendar_ops, db, tasks_ops
from .config import settings
from .owui_client import OWUIClient, OWUINotFound

# Only one push may run at a time. The 5-minute background loop and a manual
# POST /owui/sync used to be able to overlap, and when they did, one run would
# delete an event the other was mid-way through updating -> a burst of 404s.
_SYNC_LOCK = threading.Lock()


def _tz() -> ZoneInfo:
    try:
        return ZoneInfo(settings.default_timezone)
    except Exception:
        return ZoneInfo("UTC")


def _to_ns(dt: datetime) -> int:
    return int(dt.timestamp() * 1000) * 1_000_000


def _parse_dt(value: str, tz: ZoneInfo) -> datetime:
    dt = datetime.fromisoformat(value)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=tz)
    return dt


def compute_times(ev: dict[str, Any]) -> tuple[int, int | None, bool]:
    tz = _tz()
    if ev.get("all_day"):
        d = date.fromisoformat(ev["start"])
        start_at = _to_ns(datetime(d.year, d.month, d.day, tzinfo=tz))
        end_at = None
        if ev.get("end"):
            ed = date.fromisoformat(ev["end"])
            end_at = _to_ns(datetime(ed.year, ed.month, ed.day, tzinfo=tz))
        return start_at, end_at, True
    start_at = _to_ns(_parse_dt(ev["start"], tz))
    end_at = _to_ns(_parse_dt(ev["end"], tz)) if ev.get("end") else None
    return start_at, end_at, False


def signature(ev: dict[str, Any], colour: str | None) -> str:
    """Change-detection hash. Colour is included so a palette change re-pushes."""
    payload = [
        ev.get("title"),
        ev.get("start"),
        ev.get("end"),
        bool(ev.get("all_day")),
        ev.get("location"),
        ev.get("description"),
        colour,
    ]
    raw = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()


def build_form(ev: dict[str, Any], calendar_id: str, colour: str | None) -> dict[str, Any]:
    start_at, end_at, all_day = compute_times(ev)
    title = ev.get("title") or "(No title)"
    if ev.get("is_task") and settings.tasks_title_prefix:
        title = f"{settings.tasks_title_prefix}{title}"

    form: dict[str, Any] = {
        "calendar_id": calendar_id,
        "title": title,
        "description": ev.get("description"),
        "location": ev.get("location"),
        "start_at": start_at,
        "end_at": end_at,
        "all_day": all_day,
        "meta": {
            "gcal_id": ev.get("event_id"),
            "gcal_calendar_id": ev.get("calendar_id"),
            "gcal_calendar_summary": ev.get("calendar_summary"),
            "html_link": ev.get("html_link"),
            "source": "gcal-owui-bridge",
            "kind": "task" if ev.get("is_task") else "event",
        },
    }
    # OWUI's CalendarEventForm supports a per-event colour, so the colour holds
    # even in views that ignore the parent calendar's colour.
    if settings.owui_colour_events and colour:
        form["color"] = colour
    return form


# --------------------------------------------------------------------------
# Target calendar resolution (the colour-coding bit)
# --------------------------------------------------------------------------


class TargetResolver:
    """Maps a Google calendar / task list onto a coloured OWUI calendar.

    Results are cached for the duration of one sync run, so we make at most one
    OWUI round-trip per distinct source calendar.
    """

    def __init__(self, client: OWUIClient) -> None:
        self.client = client
        self._cache: dict[str, tuple[str, str | None]] = {}
        self._gcal_meta = self._load_google_meta()
        self._task_colours: dict[str, str] = {}
        self.targets: dict[str, dict[str, Any]] = {}

    @staticmethod
    def _load_google_meta() -> dict[str, dict[str, Any]]:
        meta: dict[str, dict[str, Any]] = {}
        for cal in db.list_calendars():
            raw = cal.get("raw_json") or {}
            meta[cal["id"]] = {
                "name": cal.get("summary") or raw.get("summary") or cal["id"],
                "colour": raw.get("backgroundColor") or settings.owui_default_colour,
            }
        return meta

    def prime_task_colours(self, list_titles: list[str]) -> None:
        self._task_colours = tasks_ops.task_list_colours(list_titles)

    def _desired(self, ev: dict[str, Any]) -> tuple[str, str | None]:
        """(owui calendar name, colour) for this event's source."""
        if not settings.owui_per_calendar:
            return settings.owui_target_calendar_name, settings.owui_target_calendar_color

        if ev.get("is_task"):
            title = ev.get("task_list_title") or "Tasks"
            name = settings.tasks_calendar_name_template.format(title=title)
            return name, self._task_colours.get(title, settings.tasks_palette[0])

        src_id = ev.get("calendar_id") or ""
        meta = self._gcal_meta.get(src_id) or {}
        summary = meta.get("name") or ev.get("calendar_summary") or src_id or "Google"
        name = settings.owui_calendar_name_template.format(summary=summary)
        return name, meta.get("colour") or settings.owui_default_colour

    def resolve(self, ev: dict[str, Any]) -> tuple[str, str | None]:
        name, colour = self._desired(ev)
        key = f"{name}\x00{colour}"
        if key in self._cache:
            return self._cache[key]

        cal = self.client.ensure_calendar_full(name, colour)
        cal_id = cal["id"]

        # Adopted a pre-existing calendar with the wrong colour? Recolour it.
        if (
            settings.owui_update_calendar_colours
            and colour
            and (cal.get("color") or "").lower() != colour.lower()
        ):
            try:
                self.client.update_calendar(cal_id, color=colour)
            except Exception:
                pass  # a stubborn colour must never break the sync

        self._cache[key] = (cal_id, colour)
        self.targets[cal_id] = {"name": name, "colour": colour}
        return cal_id, colour


def _in_window(start_ts: str | None, win_start: datetime, win_end: datetime) -> bool:
    if not start_ts:
        return True
    try:
        if len(start_ts) == 10:  # YYYY-MM-DD all-day
            d = date.fromisoformat(start_ts)
            dt = datetime(d.year, d.month, d.day, tzinfo=_tz())
        else:
            dt = _parse_dt(start_ts, _tz())
    except Exception:
        return True  # unparseable managed entry -> eligible for cleanup
    return win_start <= dt <= win_end


def _cleanup_legacy(client: OWUIClient, live_target_ids: set[str]) -> dict[str, Any] | None:
    """Remove the old catch-all calendar once per-calendar mode has drained it."""
    if not (settings.owui_per_calendar and settings.owui_delete_empty_legacy):
        return None
    legacy_name = settings.owui_target_calendar_name
    cal = client.find_calendar(legacy_name)
    if not cal or cal["id"] in live_target_ids:
        return None
    if cal.get("is_default") or cal.get("is_system"):
        return None
    # Only if we no longer track a single event in it.
    still_mapped = sum(1 for row in db.list_owui_map() if row.get("owui_calendar_id") == cal["id"])
    if still_mapped:
        return {"skipped": True, "reason": "still_has_managed_events", "count": still_mapped}
    try:
        client.delete_calendar(cal["id"])
        return {"deleted": True, "name": legacy_name, "id": cal["id"]}
    except Exception as exc:
        return {"deleted": False, "error": str(exc)}


def remap_calendars(dry_run: bool = False) -> dict[str, Any]:
    """Move ALREADY-SYNCED events into their correct coloured calendar.

    push_sync only ever touches events inside the rolling window, so events
    pushed by an earlier, wider run are stranded in whatever calendar they
    landed in first. This walks the whole map table and relocates anything
    sitting in the wrong place — the one-off migration to colour coding, and
    the repair path if you recolour a calendar in Google later.
    """
    if not (settings.owui_base_url and settings.owui_api_key):
        return {"skipped": True, "reason": "owui_not_configured"}
    if not settings.owui_per_calendar:
        return {"skipped": True, "reason": "per_calendar_disabled"}

    if not _SYNC_LOCK.acquire(timeout=120):
        return {"skipped": True, "reason": "another_sync_in_progress"}
    try:
        client = OWUIClient()
        resolver = TargetResolver(client)

        moved = already = skipped_tasks = pruned = 0
        errors: list[dict[str, Any]] = []

        for row in db.list_owui_map():
            gid = row["gcal_event_id"]
            src = row.get("gcal_calendar_id") or ""
            # Task rows need the list title to resolve a target, which the map
            # doesn't carry. They're always in-window, so push_sync handles them.
            if gid.startswith(tasks_ops.TASK_ID_PREFIX) or src.startswith(
                tasks_ops.TASK_CALENDAR_PREFIX
            ):
                skipped_tasks += 1
                continue
            try:
                cal_id, colour = resolver.resolve({"calendar_id": src, "is_task": False})
                if row.get("owui_calendar_id") == cal_id:
                    already += 1
                    continue
                if not dry_run:
                    try:
                        # Partial update: only the calendar and colour change.
                        client.update_event(
                            row["owui_event_id"], {"calendar_id": cal_id, "color": colour}
                        )
                    except OWUINotFound:
                        # Event is gone from OWUI; drop the dangling row.
                        db.delete_owui_map(gid)
                        pruned += 1
                        continue
                    db.upsert_owui_map(
                        gid,
                        src,
                        row["owui_event_id"],
                        cal_id,
                        row.get("start_ts"),
                        row.get("signature") or "",
                    )
                moved += 1
            except Exception as exc:
                errors.append({"gcal_id": gid, "error": str(exc)})

        legacy = None if dry_run else _cleanup_legacy(client, set(resolver.targets))
        result = {
            "moved": moved,
            "already_correct": already,
            "pruned_dangling": pruned,
            "skipped_tasks": skipped_tasks,
            "legacy_calendar": legacy,
            "errors": errors[:20],
            "error_count": len(errors),
            "dry_run": dry_run,
        }
        db.audit("owui_remap", details=result)
        return result
    finally:
        _SYNC_LOCK.release()


def push_sync(
    past_days: int | None = None,
    future_days: int | None = None,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Serialised entry point. Overlapping syncs corrupt each other's state."""
    if not _SYNC_LOCK.acquire(timeout=120):
        return {"skipped": True, "reason": "another_sync_in_progress"}
    try:
        return _push_sync(past_days=past_days, future_days=future_days, dry_run=dry_run)
    finally:
        _SYNC_LOCK.release()


def _push_sync(
    past_days: int | None = None,
    future_days: int | None = None,
    dry_run: bool = False,
) -> dict[str, Any]:
    if not (settings.owui_base_url and settings.owui_api_key):
        return {"skipped": True, "reason": "owui_not_configured"}

    past_days = settings.owui_sync_past_days if past_days is None else past_days
    future_days = settings.owui_sync_future_days if future_days is None else future_days

    client = OWUIClient()
    resolver = TargetResolver(client)

    now = datetime.now(timezone.utc)
    win_start = now - timedelta(days=past_days)
    win_end = now + timedelta(days=future_days)

    events = calendar_ops.live_events(
        start=win_start.isoformat(),
        end=win_end.isoformat(),
        include_all_selected=True,
        include_readonly=True,
    )

    # --- Google Tasks (optional, must fail soft) --------------------------
    tasks: list[dict[str, Any]] = []
    tasks_ok = False
    tasks_error: str | None = None
    if settings.tasks_sync_enabled:
        try:
            tasks = tasks_ops.live_tasks(past_days, future_days)
            tasks_ok = True
            resolver.prime_task_colours(
                sorted({t.get("task_list_title") or "Tasks" for t in tasks})
            )
        except Exception as exc:
            # Scope missing, Tasks API disabled, network blip — whatever it is,
            # we must NOT then prune task rows or we would wipe the grid.
            tasks_error = str(exc)

    seen: set[str] = set()
    created = updated = skipped = deleted = moved = healed = 0
    errors: list[dict[str, Any]] = []

    for ev in events + tasks:
        gid = ev.get("event_id")
        if not gid:
            continue
        seen.add(gid)
        try:
            cal_id, colour = resolver.resolve(ev)
            form = build_form(ev, cal_id, colour)
            sig = signature(ev, colour)
            start_iso = ev.get("start")
            row = db.get_owui_map(gid)
            if row is None:
                if not dry_run:
                    owui_id = client.create_event(form)
                    db.upsert_owui_map(gid, ev.get("calendar_id"), owui_id, cal_id, start_iso, sig)
                created += 1
            elif row["signature"] != sig or row["owui_calendar_id"] != cal_id:
                relocating = row["owui_calendar_id"] != cal_id
                if not dry_run:
                    try:
                        # CalendarEventUpdateForm accepts calendar_id, so a move
                        # is an in-place update — no delete/recreate, no lost ids.
                        client.update_event(row["owui_event_id"], form)
                        owui_id = row["owui_event_id"]
                    except OWUINotFound:
                        # Stale map row: the OWUI event is gone (deleted in the
                        # UI, or lost in a DB migration). Recreate rather than
                        # leaving a permanent hole in the grid.
                        owui_id = client.create_event(form)
                        healed += 1
                    db.upsert_owui_map(
                        gid, ev.get("calendar_id"), owui_id, cal_id, start_iso, sig
                    )
                if relocating:
                    moved += 1
                else:
                    updated += 1
            else:
                skipped += 1
        except Exception as exc:  # never let one bad event kill the whole sync
            errors.append({"gcal_id": gid, "error": str(exc)})

    # --- Deletions: managed entries that vanished from Google -------------
    for row in db.list_owui_map():
        gid = row["gcal_event_id"]
        if gid in seen:
            continue
        is_task_row = gid.startswith(tasks_ops.TASK_ID_PREFIX)
        # If the Tasks fetch failed (or is switched off) we have no idea which
        # tasks still exist, so leave every task row alone.
        if is_task_row and not tasks_ok:
            continue
        if not _in_window(row.get("start_ts"), win_start, win_end):
            continue
        try:
            if not dry_run:
                try:
                    client.delete_event(row["owui_event_id"])
                except OWUINotFound:
                    pass  # already gone in OWUI — dropping the row is the fix
                db.delete_owui_map(gid)
            deleted += 1
        except Exception as exc:
            errors.append({"gcal_id": gid, "op": "delete", "error": str(exc)})

    legacy = None if dry_run else _cleanup_legacy(client, set(resolver.targets))

    result = {
        "mode": "per-calendar" if settings.owui_per_calendar else "single-calendar",
        "calendars": [
            {"owui_calendar_id": cid, **meta} for cid, meta in resolver.targets.items()
        ],
        "window_days": {"past": past_days, "future": future_days},
        "google_events": len(events),
        "google_tasks": len(tasks),
        "tasks_enabled": settings.tasks_sync_enabled,
        "tasks_ok": tasks_ok,
        "tasks_error": tasks_error,
        "created": created,
        "updated": updated,
        "moved": moved,
        "healed": healed,
        "skipped": skipped,
        "deleted": deleted,
        "legacy_calendar": legacy,
        "errors": errors[:20],
        "error_count": len(errors),
        "dry_run": dry_run,
    }
    db.audit("owui_push_sync", details=result)
    return result
