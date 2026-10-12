from __future__ import annotations

"""Google Tasks -> normalised dicts, ready for the OWUI push sync.

Google Tasks is a SEPARATE API from Google Calendar (tasks.googleapis.com).
Task lists never appear in calendarList, which is why tasks can't be picked up
by the calendar sync no matter how it's configured.

Read-only by design: this module only ever calls list endpoints.

Normalised shape matches what owui_sync expects from calendar_ops.live_events,
with a synthetic `event_id` of `task:<tasklist_id>:<task_id>` and a synthetic
`calendar_id` of `tasks:<tasklist_id>` so the two sources share one map table
without colliding.
"""

from datetime import date, datetime, timedelta, timezone
from typing import Any

from .config import settings
from .google_client import tasks_service

TASK_ID_PREFIX = "task:"
TASK_CALENDAR_PREFIX = "tasks:"


def list_task_lists() -> list[dict[str, Any]]:
    service = tasks_service()
    lists: list[dict[str, Any]] = []
    page_token = None
    while True:
        resp = service.tasklists().list(maxResults=100, pageToken=page_token).execute()
        lists.extend(resp.get("items", []))
        page_token = resp.get("nextPageToken")
        if not page_token:
            break
    return lists


def _due_to_date(due: str | None) -> str | None:
    """Google returns due as RFC3339 with a meaningless 00:00:00Z time part.

    Only the date is significant, so we take it verbatim without timezone
    conversion — converting would drag UK tasks back a day over winter.
    """
    if not due:
        return None
    return due[:10]


def normalise_task(tasklist: dict[str, Any], task: dict[str, Any]) -> dict[str, Any]:
    list_id = tasklist.get("id")
    list_title = tasklist.get("title") or "Tasks"
    due_date = _due_to_date(task.get("due"))
    if due_date is None:
        due_date = datetime.now(timezone.utc).date().isoformat()

    start = date.fromisoformat(due_date)
    end = start + timedelta(days=1)

    completed = (task.get("status") or "").lower() == "completed"
    notes = task.get("notes") or ""
    if completed and task.get("completed"):
        notes = (notes + "\n\n" if notes else "") + f"Completed: {task['completed']}"

    return {
        "event_id": f"{TASK_ID_PREFIX}{list_id}:{task.get('id')}",
        "calendar_id": f"{TASK_CALENDAR_PREFIX}{list_id}",
        "calendar_summary": list_title,
        "title": task.get("title") or "(Untitled task)",
        "description": notes or None,
        "location": None,
        "start": start.isoformat(),
        "end": end.isoformat(),
        "all_day": True,
        "status": "completed" if completed else "needsAction",
        "html_link": task.get("webViewLink"),
        "is_task": True,
        "task_list_id": list_id,
        "task_list_title": list_title,
    }


def live_tasks(past_days: int, future_days: int) -> list[dict[str, Any]]:
    """All tasks due inside the window, normalised.

    Returns [] and raises nothing only on success; callers must treat an
    exception as "tasks unavailable" and must NOT then prune task rows.
    """
    service = tasks_service()
    now = datetime.now(timezone.utc)
    due_min = (now - timedelta(days=past_days)).isoformat().replace("+00:00", "Z")
    due_max = (now + timedelta(days=future_days)).isoformat().replace("+00:00", "Z")

    out: list[dict[str, Any]] = []
    for tasklist in list_task_lists():
        page_token = None
        while True:
            params: dict[str, Any] = {
                "tasklist": tasklist["id"],
                "maxResults": 100,
                "pageToken": page_token,
                "showCompleted": settings.tasks_include_completed,
                "showHidden": settings.tasks_include_completed,
            }
            # dueMin/dueMax silently drop undated tasks, which is exactly what
            # we want when skip_undated is on. With it off we must fetch
            # everything and filter ourselves.
            if settings.tasks_skip_undated:
                params["dueMin"] = due_min
                params["dueMax"] = due_max

            resp = service.tasks().list(**params).execute()
            for task in resp.get("items", []):
                if task.get("deleted"):
                    continue
                if settings.tasks_skip_undated and not task.get("due"):
                    continue
                if not settings.tasks_include_completed and (task.get("status") or "").lower() == "completed":
                    continue
                out.append(normalise_task(tasklist, task))
            page_token = resp.get("nextPageToken")
            if not page_token:
                break
    return out


def task_list_colours(task_lists: list[str]) -> dict[str, str]:
    """Stable colour per task list: same list always gets the same palette slot."""
    palette = settings.tasks_palette
    return {name: palette[i % len(palette)] for i, name in enumerate(sorted(task_lists))}
