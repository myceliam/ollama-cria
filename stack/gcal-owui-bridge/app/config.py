from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _bool(name: str, default: str) -> bool:
    return os.getenv(name, default).strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    app_name: str = os.getenv("APP_NAME", "Google Calendar OWUI Bridge")
    data_dir: Path = Path(os.getenv("DATA_DIR", "/data"))
    sqlite_path: Path = Path(os.getenv("SQLITE_PATH", "/data/calendar.sqlite3"))
    google_client_secret_file: Path = Path(
        os.getenv("GOOGLE_CLIENT_SECRET_FILE", "/data/client_secret.json")
    )
    google_token_file: Path = Path(os.getenv("GOOGLE_TOKEN_FILE", "/data/token.json"))
    oauth_redirect_uri: str = os.getenv(
        "OAUTH_REDIRECT_URI", "http://127.0.0.1:18100/auth/callback"
    )
    default_timezone: str = os.getenv("DEFAULT_TIMEZONE", "Europe/London")
    api_key: str | None = os.getenv("GCAL_BRIDGE_API_KEY") or None
    enable_background_sync: bool = _bool("ENABLE_BACKGROUND_SYNC", "true")
    sync_interval_seconds: int = int(os.getenv("SYNC_INTERVAL_SECONDS", "300"))
    max_live_window_days: int = int(os.getenv("MAX_LIVE_WINDOW_DAYS", "730"))
    default_live_future_days: int = int(os.getenv("DEFAULT_LIVE_FUTURE_DAYS", "30"))
    default_live_past_days: int = int(os.getenv("DEFAULT_LIVE_PAST_DAYS", "0"))

    # --- Push sync INTO Open WebUI's built-in Calendar grid ---
    owui_base_url: str | None = os.getenv("OWUI_BASE_URL") or None
    owui_api_key: str | None = os.getenv("OWUI_API_KEY") or None
    owui_request_timeout: int = int(os.getenv("OWUI_REQUEST_TIMEOUT", "20"))
    owui_sync_enabled: bool = _bool("OWUI_SYNC_ENABLED", "false")
    owui_sync_interval_seconds: int = int(os.getenv("OWUI_SYNC_INTERVAL_SECONDS", "300"))
    owui_sync_past_days: int = int(os.getenv("OWUI_SYNC_PAST_DAYS", "30"))
    owui_sync_future_days: int = int(os.getenv("OWUI_SYNC_FUTURE_DAYS", "180"))

    # --- Per-calendar colour coding ---
    # When true (default), each Google calendar gets its OWN OpenWebUI calendar,
    # coloured with that Google calendar's own backgroundColor. When false, the
    # legacy behaviour applies and everything lands in one catch-all calendar.
    owui_per_calendar: bool = _bool("OWUI_PER_CALENDAR", "true")
    # Template for the OWUI calendar name. {summary} = Google calendar name.
    owui_calendar_name_template: str = os.getenv("OWUI_CALENDAR_NAME_TEMPLATE", "{summary}")
    # Also stamp each event with its calendar's colour, so colours survive in
    # merged/agenda views that ignore the parent calendar's colour.
    owui_colour_events: bool = _bool("OWUI_COLOUR_EVENTS", "true")
    # Keep existing OWUI calendar colours in step with Google's.
    owui_update_calendar_colours: bool = _bool("OWUI_UPDATE_CALENDAR_COLOURS", "true")
    # Fallback colour when Google gives us none.
    owui_default_colour: str = os.getenv("OWUI_DEFAULT_COLOUR", "#22c55e")

    # --- Legacy single-calendar mode / migration ---
    owui_target_calendar_name: str = os.getenv("OWUI_TARGET_CALENDAR_NAME", "Google")
    owui_target_calendar_color: str = os.getenv("OWUI_TARGET_CALENDAR_COLOR", "#22c55e")
    # After migrating to per-calendar mode, remove the old catch-all calendar
    # if (and only if) it ends up holding none of our managed events.
    owui_delete_empty_legacy: bool = _bool("OWUI_DELETE_EMPTY_LEGACY", "true")

    # --- Google Tasks -> OWUI (read-only) ---
    tasks_sync_enabled: bool = _bool("TASKS_SYNC_ENABLED", "false")
    # {title} = Google task list name.
    tasks_calendar_name_template: str = os.getenv("TASKS_CALENDAR_NAME_TEMPLATE", "{title}")
    # Google Tasks has no per-list colour, so we rotate through this palette.
    tasks_colour_palette: str = os.getenv(
        "TASKS_COLOUR_PALETTE", "#f59e0b,#8b5cf6,#ec4899,#14b8a6,#ef4444"
    )
    tasks_include_completed: bool = _bool("TASKS_INCLUDE_COMPLETED", "false")
    # Tasks with no due date can't be placed on a grid; skip them by default.
    tasks_skip_undated: bool = _bool("TASKS_SKIP_UNDATED", "true")
    tasks_title_prefix: str = os.getenv("TASKS_TITLE_PREFIX", "")

    # --- Real-time push (Google Calendar watch channels) ---
    # OFF until you set WEBHOOK_PUBLIC_URL + verify the domain in Google Cloud.
    watch_enabled: bool = _bool("WATCH_ENABLED", "false")
    webhook_public_url: str | None = os.getenv("WEBHOOK_PUBLIC_URL") or None  # e.g. https://cal.myceliam.uk/google/notifications
    watch_token: str | None = os.getenv("WATCH_TOKEN") or None  # shared secret Google echoes back in X-Goog-Channel-Token
    watch_ttl_seconds: int = int(os.getenv("WATCH_TTL_SECONDS", "604800"))  # channel lifetime (~7 days max for Calendar)
    watch_renew_margin_seconds: int = int(os.getenv("WATCH_RENEW_MARGIN_SECONDS", "86400"))  # renew when <1 day left
    watch_renew_check_seconds: int = int(os.getenv("WATCH_RENEW_CHECK_SECONDS", "3600"))  # how often the renewal loop checks
    watch_debounce_seconds: int = int(os.getenv("WATCH_DEBOUNCE_SECONDS", "3"))  # coalesce notification bursts into one sync

    @property
    def oauth_state_file(self) -> Path:
        return self.data_dir / "oauth_state.txt"

    @property
    def tasks_palette(self) -> list[str]:
        colours = [c.strip() for c in self.tasks_colour_palette.split(",") if c.strip()]
        return colours or ["#f59e0b"]


settings = Settings()
settings.data_dir.mkdir(parents=True, exist_ok=True)
