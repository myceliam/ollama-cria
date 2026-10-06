from __future__ import annotations

from typing import Any

from fastapi import Depends, FastAPI, Header, HTTPException, Query
from fastapi.responses import HTMLResponse, PlainTextResponse
from googleapiclient.errors import HttpError

from . import gmail_ops
from .config import settings
from .google_client import (
    client_secret_available,
    complete_oauth_callback,
    credentials_available,
    google_error_to_http,
    make_auth_url,
)
from .schemas import (
    CreateLabelRequest,
    DraftCreateRequest,
    DraftSendRequest,
    IdRequest,
    ModifyLabelsRequest,
    ReplyRequest,
    SendRequest,
)

app = FastAPI(
    title="Gmail OWUI Bridge",
    version="1.0.0",
    description=(
        "Open WebUI-ready Gmail bridge: search/read mail, manage drafts and labels, "
        "and send/reply with a confirm-then-send safety guard. Reuses the existing "
        "Desktop Google OAuth client; single gmail.modify scope."
    ),
)


async def require_api_key(
    x_api_key: str | None = Header(default=None),
    authorization: str | None = Header(default=None),
) -> None:
    if not settings.api_key:
        return
    token = x_api_key
    if not token and authorization and authorization.lower().startswith("bearer "):
        token = authorization[7:].strip()
    if token != settings.api_key:
        raise HTTPException(
            status_code=401,
            detail="Missing or invalid API key (send X-API-Key or Authorization: Bearer)",
        )


@app.get("/", response_class=HTMLResponse, include_in_schema=False)
def root() -> str:
    return """
    <html>
      <head><title>Gmail OWUI Bridge</title></head>
      <body style="font-family: sans-serif; max-width: 900px; margin: 2rem auto; line-height: 1.5;">
        <h1>Gmail OWUI Bridge</h1>
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
        "api_key_required": bool(settings.api_key),
    }


@app.get("/auth/status", tags=["auth"], dependencies=[Depends(require_api_key)])
def auth_status() -> dict[str, Any]:
    return {
        "authenticated": credentials_available(),
        "client_secret_present": client_secret_available(),
        "client_secret_path": str(settings.google_client_secret_file),
        "token_path": str(settings.google_token_file),
        "redirect_uri": settings.oauth_redirect_uri,
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
        <h1>Gmail authorised ✅</h1>
        <p>You can close this tab and return to Open WebUI.</p>
        <pre>{result}</pre>
        </body></html>
        """
    )


# --- Identity ---------------------------------------------------------------

@app.get("/profile", tags=["system"], dependencies=[Depends(require_api_key)])
def get_profile() -> dict[str, Any]:
    try:
        return gmail_ops.profile()
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


# --- Send / reply (confirm-then-send) --------------------------------------

@app.post("/messages/send", tags=["send"], dependencies=[Depends(require_api_key)])
def send(payload: SendRequest) -> dict[str, Any]:
    """Send a new email. Safety: with confirm=false (default) this returns a
    PREVIEW and sends nothing. Show the preview to the user, then call again with
    confirm=true to actually send."""
    try:
        return gmail_ops.send_message(payload)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.post("/messages/reply", tags=["send"], dependencies=[Depends(require_api_key)])
def reply(payload: ReplyRequest) -> dict[str, Any]:
    """Reply within an existing thread. confirm=false returns a preview; confirm=true sends."""
    try:
        return gmail_ops.reply_message(payload)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


# --- Drafts -----------------------------------------------------------------

@app.post("/drafts/create", tags=["drafts"], dependencies=[Depends(require_api_key)])
def draft_create(payload: DraftCreateRequest) -> dict[str, Any]:
    try:
        return gmail_ops.create_draft(payload)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.get("/drafts", tags=["drafts"], dependencies=[Depends(require_api_key)])
def drafts_list(max_results: int = Query(default=20, ge=1, le=100)) -> dict[str, Any]:
    try:
        return gmail_ops.list_drafts(max_results)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.post("/drafts/send", tags=["drafts"], dependencies=[Depends(require_api_key)])
def draft_send(payload: DraftSendRequest) -> dict[str, Any]:
    """Send an existing draft. confirm must be true."""
    try:
        return gmail_ops.send_draft(payload.draft_id, payload.confirm)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.post("/drafts/delete", tags=["drafts"], dependencies=[Depends(require_api_key)])
def draft_delete(payload: IdRequest) -> dict[str, Any]:
    try:
        return gmail_ops.delete_draft(payload.id)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


# --- Read / search ----------------------------------------------------------

@app.get("/messages/search", tags=["read"], dependencies=[Depends(require_api_key)])
def messages_search(
    q: str | None = Query(default=None, description="Gmail search query, e.g. 'from:bank is:unread newer_than:7d'."),
    max_results: int | None = Query(default=None, ge=1, le=100),
) -> dict[str, Any]:
    """Search mail using Gmail's query syntax. Returns compact metadata + snippets."""
    try:
        return gmail_ops.search_messages(q, max_results or settings.default_search_max)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.get("/messages/get", tags=["read"], dependencies=[Depends(require_api_key)])
def message_get(id: str) -> dict[str, Any]:
    """Get one message's full headers + decoded body."""
    try:
        return gmail_ops.get_message(id)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.get("/threads/get", tags=["read"], dependencies=[Depends(require_api_key)])
def thread_get(id: str) -> dict[str, Any]:
    """Get every message in a thread (for context before replying)."""
    try:
        return gmail_ops.get_thread(id)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


# --- Labels & modify --------------------------------------------------------

@app.get("/labels", tags=["labels"], dependencies=[Depends(require_api_key)])
def labels_list() -> dict[str, Any]:
    try:
        return gmail_ops.list_labels()
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.post("/labels/create", tags=["labels"], dependencies=[Depends(require_api_key)])
def label_create(payload: CreateLabelRequest) -> dict[str, Any]:
    try:
        return gmail_ops.create_label(payload.name)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.post("/messages/modify", tags=["labels"], dependencies=[Depends(require_api_key)])
def message_modify(payload: ModifyLabelsRequest) -> dict[str, Any]:
    """Add/remove label IDs on a message (get IDs from /labels)."""
    try:
        return gmail_ops.modify_labels(payload.id, payload.add_label_ids, payload.remove_label_ids)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.post("/messages/mark_read", tags=["labels"], dependencies=[Depends(require_api_key)])
def message_mark_read(payload: IdRequest, read: bool = Query(default=True)) -> dict[str, Any]:
    try:
        return gmail_ops.mark_read(payload.id, read)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.post("/messages/archive", tags=["labels"], dependencies=[Depends(require_api_key)])
def message_archive(payload: IdRequest) -> dict[str, Any]:
    try:
        return gmail_ops.archive(payload.id)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.post("/messages/trash", tags=["labels"], dependencies=[Depends(require_api_key)])
def message_trash(payload: IdRequest) -> dict[str, Any]:
    """Move a message to Trash (recoverable ~30 days). No permanent delete by design."""
    try:
        return gmail_ops.trash(payload.id)
    except HttpError as exc:
        raise google_error_to_http(exc) from exc


@app.get("/robots.txt", include_in_schema=False)
def robots() -> PlainTextResponse:
    return PlainTextResponse("User-agent: *\nDisallow: /\n")
