from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator


class FullSyncRequest(BaseModel):
    calendar_ids: list[str] | None = Field(default=None, description="Calendar IDs to sync. Null means selected calendars.")
    include_readonly: bool = Field(default=True, description="Whether to include read-only calendars in cache sync.")


class IncrementalSyncRequest(BaseModel):
    calendar_ids: list[str] | None = Field(default=None, description="Calendar IDs to sync. Null means selected calendars.")
    include_readonly: bool = True
    full_sync_if_missing_token: bool = True


class SelectCalendarRequest(BaseModel):
    calendar_id: str
    selected: bool


class EventCreateRequest(BaseModel):
    calendar_id: str = "primary"
    title: str = Field(min_length=1, max_length=1024)
    start: str = Field(description="RFC3339 datetime, e.g. 2026-06-25T10:00:00+01:00, or YYYY-MM-DD if all_day=true")
    end: str = Field(description="RFC3339 datetime, e.g. 2026-06-25T10:30:00+01:00, or YYYY-MM-DD if all_day=true")
    timezone: str = "Europe/London"
    all_day: bool = False
    description: str | None = None
    location: str | None = None
    attendees: list[str] = Field(default_factory=list)
    reminder_minutes: int | None = Field(default=30, ge=0, le=40320)
    recurrence: list[str] | None = Field(
        default=None,
        description="Recurrence rules for repeating events, e.g. ['RRULE:FREQ=WEEKLY;BYDAY=MO']. Omit for a one-off event.",
    )

    @field_validator("attendees")
    @classmethod
    def trim_attendees(cls, value: list[str]) -> list[str]:
        return [email.strip() for email in value if email.strip()]


class EventPatchRequest(BaseModel):
    calendar_id: str = "primary"
    event_id: str
    title: str | None = Field(default=None, max_length=1024)
    start: str | None = None
    end: str | None = None
    timezone: str = "Europe/London"
    all_day: bool = False
    description: str | None = None
    location: str | None = None
    reminder_minutes: int | None = Field(default=None, ge=0, le=40320)
    clear_reminders: bool = False
    recurrence: list[str] | None = Field(
        default=None,
        description="Replace recurrence rules, e.g. ['RRULE:FREQ=WEEKLY;BYDAY=MO']. Omit to leave unchanged.",
    )


class DeleteEventRequest(BaseModel):
    calendar_id: str = "primary"
    event_id: str
    confirmed: bool = Field(default=False, description="Must be true. This deliberately prevents accidental model deletes.")


class FreeBusyRequest(BaseModel):
    start: str
    end: str
    calendar_ids: list[str] = Field(default_factory=lambda: ["primary"])
    timezone: str = "Europe/London"


class LiveEventsResponse(BaseModel):
    source: Literal["google_calendar_live"] = "google_calendar_live"
    count: int
    events: list[dict[str, Any]]
