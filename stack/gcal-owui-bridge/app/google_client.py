from __future__ import annotations

from typing import Any

from fastapi import HTTPException
from google.auth.exceptions import RefreshError
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import Flow
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError

from .config import settings

CALENDAR_SCOPE = "https://www.googleapis.com/auth/calendar"
# Read-only on purpose: the bridge must never be able to complete or delete a
# real Google task, no matter how creative a chat model gets.
TASKS_SCOPE = "https://www.googleapis.com/auth/tasks.readonly"

SCOPES = [CALENDAR_SCOPE, TASKS_SCOPE]


def credentials_available() -> bool:
    return settings.google_token_file.exists()


def granted_scopes() -> list[str]:
    """Scopes actually present on the stored token (not the ones we ask for)."""
    if not settings.google_token_file.exists():
        return []
    try:
        import json

        data = json.loads(settings.google_token_file.read_text(encoding="utf-8"))
    except Exception:
        return []
    scopes = data.get("scopes") or []
    if isinstance(scopes, str):
        scopes = scopes.split()
    return list(scopes)


def has_scope(scope: str) -> bool:
    return scope in granted_scopes()


def client_secret_available() -> bool:
    return settings.google_client_secret_file.exists()


def load_credentials() -> Credentials:
    if not settings.google_token_file.exists():
        raise HTTPException(
            status_code=401,
            detail={
                "error": "not_authenticated",
                "message": "No Google token exists yet. Visit /auth/url first, then complete OAuth.",
            },
        )

    creds = Credentials.from_authorized_user_file(str(settings.google_token_file), SCOPES)
    if creds.expired and creds.refresh_token:
        try:
            creds.refresh(Request())
            save_credentials(creds)
        except RefreshError as exc:
            raise HTTPException(
                status_code=401,
                detail={
                    "error": "token_refresh_failed",
                    "message": "Google token refresh failed. Re-run OAuth.",
                    "details": str(exc),
                },
            ) from exc
    if not creds.valid:
        raise HTTPException(
            status_code=401,
            detail={
                "error": "invalid_credentials",
                "message": "Google credentials are invalid. Re-run OAuth.",
            },
        )
    return creds


def save_credentials(creds: Credentials) -> None:
    settings.google_token_file.parent.mkdir(parents=True, exist_ok=True)
    settings.google_token_file.write_text(creds.to_json(), encoding="utf-8")


def calendar_service() -> Any:
    creds = load_credentials()
    return build("calendar", "v3", credentials=creds, cache_discovery=False)


def tasks_service() -> Any:
    """Google Tasks API client.

    Requires BOTH the tasks.readonly scope on the token AND the Tasks API
    enabled in the Google Cloud project. Missing either produces a 403 from
    Google, so we fail loudly here with a fixable message.
    """
    if not has_scope(TASKS_SCOPE):
        raise HTTPException(
            status_code=403,
            detail={
                "error": "tasks_scope_missing",
                "message": (
                    "The stored Google token has no tasks.readonly scope. "
                    "Re-run OAuth via /auth/url to grant it."
                ),
                "granted_scopes": granted_scopes(),
            },
        )
    creds = load_credentials()
    return build("tasks", "v1", credentials=creds, cache_discovery=False)


def make_auth_url() -> dict[str, str]:
    if not settings.google_client_secret_file.exists():
        raise HTTPException(
            status_code=400,
            detail={
                "error": "missing_client_secret",
                "message": f"Put your OAuth client JSON at {settings.google_client_secret_file}",
            },
        )

    flow = Flow.from_client_secrets_file(
        str(settings.google_client_secret_file),
        scopes=SCOPES,
        redirect_uri=settings.oauth_redirect_uri,
    )
    auth_url, state = flow.authorization_url(
        access_type="offline",
        include_granted_scopes="true",
        prompt="consent",
    )
    settings.oauth_state_file.write_text(state, encoding="utf-8")
    return {"authorization_url": auth_url, "state": state, "redirect_uri": settings.oauth_redirect_uri}


def complete_oauth_callback(code: str, state: str | None) -> dict[str, Any]:
    expected_state = None
    if settings.oauth_state_file.exists():
        expected_state = settings.oauth_state_file.read_text(encoding="utf-8").strip()

    if expected_state and state != expected_state:
        raise HTTPException(
            status_code=400,
            detail={
                "error": "invalid_state",
                "message": "OAuth state did not match. Start the OAuth flow again from /auth/url.",
            },
        )

    flow = Flow.from_client_secrets_file(
        str(settings.google_client_secret_file),
        scopes=SCOPES,
        redirect_uri=settings.oauth_redirect_uri,
    )
    flow.fetch_token(code=code)
    creds = flow.credentials
    save_credentials(creds)
    return {
        "authenticated": True,
        "scopes": list(creds.scopes or SCOPES),
        "expiry": creds.expiry.isoformat() if creds.expiry else None,
    }


def google_error_to_http(exc: HttpError) -> HTTPException:
    status = getattr(exc.resp, "status", 500)
    reason = getattr(exc, "reason", str(exc))
    return HTTPException(status_code=status, detail={"error": "google_api_error", "message": reason})
