from __future__ import annotations

import json
import sqlite3
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

from .config import settings


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def json_dumps(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def json_loads(value: str | None) -> Any:
    if not value:
        return None
    return json.loads(value)


@contextmanager
def connect() -> Iterable[sqlite3.Connection]:
    db_path: Path = settings.sqlite_path
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA foreign_keys=ON;")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db() -> None:
    with connect() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS calendars (
                id TEXT PRIMARY KEY,
                summary TEXT,
                description TEXT,
                time_zone TEXT,
                access_role TEXT,
                primary_flag INTEGER DEFAULT 0,
                selected INTEGER DEFAULT 1,
                raw_json TEXT NOT NULL,
                updated_at TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS events (
                calendar_id TEXT NOT NULL,
                event_id TEXT NOT NULL,
                summary TEXT,
                description TEXT,
                location TEXT,
                status TEXT,
                start_raw TEXT,
                end_raw TEXT,
                start_ts TEXT,
                end_ts TEXT,
                updated_ts TEXT,
                recurring_event_id TEXT,
                html_link TEXT,
                raw_json TEXT NOT NULL,
                deleted INTEGER DEFAULT 0,
                cached_at TEXT NOT NULL,
                PRIMARY KEY(calendar_id, event_id),
                FOREIGN KEY(calendar_id) REFERENCES calendars(id) ON DELETE CASCADE
            );

            CREATE INDEX IF NOT EXISTS idx_events_start_ts ON events(start_ts);
            CREATE INDEX IF NOT EXISTS idx_events_updated_ts ON events(updated_ts);
            CREATE INDEX IF NOT EXISTS idx_events_summary ON events(summary);
            CREATE INDEX IF NOT EXISTS idx_events_deleted ON events(deleted);

            CREATE TABLE IF NOT EXISTS sync_state (
                calendar_id TEXT PRIMARY KEY,
                sync_token TEXT,
                last_full_sync TEXT,
                last_incremental_sync TEXT,
                last_error TEXT,
                FOREIGN KEY(calendar_id) REFERENCES calendars(id) ON DELETE CASCADE
            );

            CREATE TABLE IF NOT EXISTS audit_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts TEXT NOT NULL,
                action TEXT NOT NULL,
                calendar_id TEXT,
                event_id TEXT,
                details_json TEXT
            );

            -- Maps a Google event (expanded instance id) to the OWUI calendar
            -- event it was mirrored into, so re-syncs update instead of duplicate.
            CREATE TABLE IF NOT EXISTS owui_map (
                gcal_event_id TEXT PRIMARY KEY,
                gcal_calendar_id TEXT,
                owui_event_id TEXT NOT NULL,
                owui_calendar_id TEXT NOT NULL,
                start_ts TEXT,
                signature TEXT,
                synced_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_owui_map_start ON owui_map(start_ts);
            """
        )


def get_owui_map(gcal_event_id: str) -> dict[str, Any] | None:
    with connect() as conn:
        row = conn.execute(
            "SELECT * FROM owui_map WHERE gcal_event_id = ?", (gcal_event_id,)
        ).fetchone()
    return dict(row) if row else None


def upsert_owui_map(
    gcal_event_id: str,
    gcal_calendar_id: str | None,
    owui_event_id: str,
    owui_calendar_id: str,
    start_ts: str | None,
    signature: str,
) -> None:
    with connect() as conn:
        conn.execute(
            """
            INSERT INTO owui_map (
                gcal_event_id, gcal_calendar_id, owui_event_id, owui_calendar_id,
                start_ts, signature, synced_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(gcal_event_id) DO UPDATE SET
                gcal_calendar_id = excluded.gcal_calendar_id,
                owui_event_id = excluded.owui_event_id,
                owui_calendar_id = excluded.owui_calendar_id,
                start_ts = excluded.start_ts,
                signature = excluded.signature,
                synced_at = excluded.synced_at
            """,
            (
                gcal_event_id,
                gcal_calendar_id,
                owui_event_id,
                owui_calendar_id,
                start_ts,
                signature,
                utc_now_iso(),
            ),
        )


def delete_owui_map(gcal_event_id: str) -> None:
    with connect() as conn:
        conn.execute("DELETE FROM owui_map WHERE gcal_event_id = ?", (gcal_event_id,))


def list_owui_map() -> list[dict[str, Any]]:
    with connect() as conn:
        rows = conn.execute("SELECT * FROM owui_map").fetchall()
    return [dict(row) for row in rows]


def count_owui_map() -> int:
    with connect() as conn:
        return conn.execute("SELECT COUNT(*) FROM owui_map").fetchone()[0]


def upsert_calendar(calendar: dict[str, Any]) -> None:
    with connect() as conn:
        conn.execute(
            """
            INSERT INTO calendars (
                id, summary, description, time_zone, access_role, primary_flag,
                selected, raw_json, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, COALESCE((SELECT selected FROM calendars WHERE id = ?), 1), ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                summary = excluded.summary,
                description = excluded.description,
                time_zone = excluded.time_zone,
                access_role = excluded.access_role,
                primary_flag = excluded.primary_flag,
                raw_json = excluded.raw_json,
                updated_at = excluded.updated_at
            """,
            (
                calendar.get("id"),
                calendar.get("summary"),
                calendar.get("description"),
                calendar.get("timeZone"),
                calendar.get("accessRole"),
                1 if calendar.get("primary") else 0,
                calendar.get("id"),
                json_dumps(calendar),
                utc_now_iso(),
            ),
        )
        conn.execute(
            "INSERT OR IGNORE INTO sync_state(calendar_id) VALUES (?)", (calendar.get("id"),)
        )


def set_calendar_selected(calendar_id: str, selected: bool) -> None:
    with connect() as conn:
        conn.execute(
            "UPDATE calendars SET selected = ?, updated_at = ? WHERE id = ?",
            (1 if selected else 0, utc_now_iso(), calendar_id),
        )


def list_calendars(selected_only: bool = False) -> list[dict[str, Any]]:
    sql = "SELECT * FROM calendars"
    params: tuple[Any, ...] = ()
    if selected_only:
        sql += " WHERE selected = 1"
    sql += " ORDER BY primary_flag DESC, summary COLLATE NOCASE"
    with connect() as conn:
        rows = conn.execute(sql, params).fetchall()
    return [row_to_dict(row) for row in rows]


def row_to_dict(row: sqlite3.Row) -> dict[str, Any]:
    result = dict(row)
    for key in ("raw_json", "details_json"):
        if key in result:
            result[key] = json_loads(result[key])
    return result


def extract_event_times(event: dict[str, Any]) -> tuple[str | None, str | None, str | None, str | None]:
    start_obj = event.get("start") or {}
    end_obj = event.get("end") or {}
    start_raw = json_dumps(start_obj)
    end_raw = json_dumps(end_obj)
    start_ts = start_obj.get("dateTime") or start_obj.get("date")
    end_ts = end_obj.get("dateTime") or end_obj.get("date")
    return start_raw, end_raw, start_ts, end_ts


def upsert_event(calendar_id: str, event: dict[str, Any]) -> None:
    start_raw, end_raw, start_ts, end_ts = extract_event_times(event)
    deleted = 1 if event.get("status") == "cancelled" else 0
    with connect() as conn:
        conn.execute(
            """
            INSERT INTO events (
                calendar_id, event_id, summary, description, location, status,
                start_raw, end_raw, start_ts, end_ts, updated_ts,
                recurring_event_id, html_link, raw_json, deleted, cached_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(calendar_id, event_id) DO UPDATE SET
                summary = excluded.summary,
                description = excluded.description,
                location = excluded.location,
                status = excluded.status,
                start_raw = excluded.start_raw,
                end_raw = excluded.end_raw,
                start_ts = excluded.start_ts,
                end_ts = excluded.end_ts,
                updated_ts = excluded.updated_ts,
                recurring_event_id = excluded.recurring_event_id,
                html_link = excluded.html_link,
                raw_json = excluded.raw_json,
                deleted = excluded.deleted,
                cached_at = excluded.cached_at
            """,
            (
                calendar_id,
                event.get("id"),
                event.get("summary"),
                event.get("description"),
                event.get("location"),
                event.get("status"),
                start_raw,
                end_raw,
                start_ts,
                end_ts,
                event.get("updated"),
                event.get("recurringEventId"),
                event.get("htmlLink"),
                json_dumps(event),
                deleted,
                utc_now_iso(),
            ),
        )


def mark_event_deleted(calendar_id: str, event_id: str, raw_event: dict[str, Any] | None = None) -> None:
    raw = raw_event or {"id": event_id, "status": "cancelled"}
    with connect() as conn:
        conn.execute(
            """
            INSERT INTO events (
                calendar_id, event_id, summary, status, raw_json, deleted, cached_at
            ) VALUES (?, ?, ?, 'cancelled', ?, 1, ?)
            ON CONFLICT(calendar_id, event_id) DO UPDATE SET
                status = 'cancelled',
                raw_json = excluded.raw_json,
                deleted = 1,
                cached_at = excluded.cached_at
            """,
            (calendar_id, event_id, raw.get("summary"), json_dumps(raw), utc_now_iso()),
        )


def clear_calendar_events(calendar_id: str) -> None:
    with connect() as conn:
        conn.execute("DELETE FROM events WHERE calendar_id = ?", (calendar_id,))


def set_sync_token(calendar_id: str, token: str | None, full: bool = False, error: str | None = None) -> None:
    now = utc_now_iso()
    with connect() as conn:
        conn.execute(
            "INSERT OR IGNORE INTO sync_state(calendar_id) VALUES (?)", (calendar_id,)
        )
        if full:
            conn.execute(
                """
                UPDATE sync_state
                SET sync_token = ?, last_full_sync = ?, last_error = ?
                WHERE calendar_id = ?
                """,
                (token, now, error, calendar_id),
            )
        else:
            conn.execute(
                """
                UPDATE sync_state
                SET sync_token = ?, last_incremental_sync = ?, last_error = ?
                WHERE calendar_id = ?
                """,
                (token, now, error, calendar_id),
            )


def set_sync_error(calendar_id: str, error: str) -> None:
    with connect() as conn:
        conn.execute(
            "INSERT OR IGNORE INTO sync_state(calendar_id) VALUES (?)", (calendar_id,)
        )
        conn.execute(
            "UPDATE sync_state SET last_error = ? WHERE calendar_id = ?",
            (error, calendar_id),
        )


def get_sync_state(calendar_id: str) -> dict[str, Any] | None:
    with connect() as conn:
        row = conn.execute(
            "SELECT * FROM sync_state WHERE calendar_id = ?", (calendar_id,)
        ).fetchone()
    return row_to_dict(row) if row else None


def list_sync_state() -> list[dict[str, Any]]:
    with connect() as conn:
        rows = conn.execute(
            """
            SELECT s.*, c.summary, c.access_role, c.selected
            FROM sync_state s
            LEFT JOIN calendars c ON c.id = s.calendar_id
            ORDER BY c.primary_flag DESC, c.summary COLLATE NOCASE
            """
        ).fetchall()
    return [row_to_dict(row) for row in rows]


def search_cached_events(
    q: str | None = None,
    start: str | None = None,
    end: str | None = None,
    include_deleted: bool = False,
    limit: int = 100,
) -> list[dict[str, Any]]:
    clauses: list[str] = []
    params: list[Any] = []

    if not include_deleted:
        clauses.append("e.deleted = 0")
    if q:
        like = f"%{q}%"
        clauses.append(
            "(e.summary LIKE ? OR e.description LIKE ? OR e.location LIKE ? OR e.raw_json LIKE ?)"
        )
        params.extend([like, like, like, like])
    if start:
        clauses.append("(e.end_ts IS NULL OR e.end_ts >= ?)")
        params.append(start)
    if end:
        clauses.append("(e.start_ts IS NULL OR e.start_ts <= ?)")
        params.append(end)

    where = " WHERE " + " AND ".join(clauses) if clauses else ""
    sql = f"""
        SELECT e.*, c.summary AS calendar_summary
        FROM events e
        LEFT JOIN calendars c ON c.id = e.calendar_id
        {where}
        ORDER BY COALESCE(e.start_ts, e.updated_ts, e.cached_at) ASC
        LIMIT ?
    """
    params.append(max(1, min(limit, 500)))
    with connect() as conn:
        rows = conn.execute(sql, params).fetchall()
    return [row_to_dict(row) for row in rows]


def audit(action: str, calendar_id: str | None = None, event_id: str | None = None, details: Any = None) -> None:
    with connect() as conn:
        conn.execute(
            """
            INSERT INTO audit_log(ts, action, calendar_id, event_id, details_json)
            VALUES (?, ?, ?, ?, ?)
            """,
            (utc_now_iso(), action, calendar_id, event_id, json_dumps(details or {})),
        )


def latest_audit(limit: int = 50) -> list[dict[str, Any]]:
    with connect() as conn:
        rows = conn.execute(
            "SELECT * FROM audit_log ORDER BY id DESC LIMIT ?", (max(1, min(limit, 200)),)
        ).fetchall()
    return [row_to_dict(row) for row in rows]
