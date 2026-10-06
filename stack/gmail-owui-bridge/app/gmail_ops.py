from __future__ import annotations

import base64
import json
import mimetypes
import re
from datetime import datetime, timezone
from email.message import EmailMessage
from email.utils import formataddr, parseaddr
from pathlib import Path
from typing import Any

from .config import settings
from .google_client import gmail_service
from .schemas import (
    DraftCreateRequest,
    ReplyRequest,
    SendRequest,
)

# ---------------------------------------------------------------------------
# MIME helpers
# ---------------------------------------------------------------------------

def _attach_files(msg: EmailMessage, paths: list[str]) -> list[str]:
    """Attach each file after validating it against the security policy.

    A path must resolve to a real file *under* one of settings.attachment_allowed_dirs
    (blocks path traversal and reading secrets like /app/secrets) and be within the
    size cap. Returns the attached filenames; raises ValueError on any violation.
    """
    allowed_roots = [Path(d).resolve() for d in settings.attachment_allowed_dirs]
    attached: list[str] = []
    for raw in paths:
        fp = Path(raw).resolve()
        if not any(fp == root or root in fp.parents for root in allowed_roots):
            raise ValueError(
                f"attachment path not allowed: {raw} "
                f"(must be under {', '.join(settings.attachment_allowed_dirs)})"
            )
        if not fp.is_file():
            raise ValueError(f"attachment not found: {raw}")
        size = fp.stat().st_size
        if size > settings.max_attachment_bytes:
            raise ValueError(
                f"attachment too large: {raw} ({size} bytes > {settings.max_attachment_bytes})"
            )
        ctype, _ = mimetypes.guess_type(str(fp))
        maintype, subtype = (ctype.split("/", 1) if ctype else ("application", "octet-stream"))
        msg.add_attachment(fp.read_bytes(), maintype=maintype, subtype=subtype, filename=fp.name)
        attached.append(fp.name)
    return attached


def _build_mime(
    *,
    to: list[str],
    subject: str,
    body: str,
    cc: list[str] | None = None,
    bcc: list[str] | None = None,
    html: bool = False,
    reply_to: str | None = None,
    from_addr: str | None = None,
    extra_headers: dict[str, str] | None = None,
    attachments: list[str] | None = None,
) -> EmailMessage:
    msg = EmailMessage()
    if from_addr:
        msg["From"] = from_addr
    if to:
        msg["To"] = ", ".join(to)
    if cc:
        msg["Cc"] = ", ".join(cc)
    if bcc:
        msg["Bcc"] = ", ".join(bcc)
    msg["Subject"] = subject or ""
    if reply_to:
        msg["Reply-To"] = reply_to
    for k, v in (extra_headers or {}).items():
        if v:
            msg[k] = v
    if html:
        msg.set_content("This message requires an HTML-capable client.")
        msg.add_alternative(body or "", subtype="html")
    else:
        msg.set_content(body or "")
    if attachments:
        _attach_files(msg, attachments)
    return msg


def _raw(msg: EmailMessage) -> str:
    return base64.urlsafe_b64encode(msg.as_bytes()).decode()


def _preview(to, subject, body, cc=None, bcc=None, html=False, thread_id=None) -> dict[str, Any]:
    snippet = (body or "")[: settings.body_snippet_chars]
    return {
        "sent": False,
        "preview": True,
        "instruction": "Show this to the user. To actually send, call the same endpoint again with confirm=true.",
        "message": {
            "to": to,
            "cc": cc or [],
            "bcc": bcc or [],
            "subject": subject,
            "html": html,
            "thread_id": thread_id,
            "body": snippet,
            "body_truncated": len(body or "") > settings.body_snippet_chars,
        },
    }


def _log_sent(kind: str, info: dict[str, Any]) -> None:
    try:
        entries: list[dict[str, Any]] = []
        if settings.sent_log_file.exists():
            entries = json.loads(settings.sent_log_file.read_text(encoding="utf-8"))
        entries.append({"ts": datetime.now(timezone.utc).isoformat(), "kind": kind, **info})
        entries = entries[-200:]
        settings.sent_log_file.write_text(json.dumps(entries, indent=2), encoding="utf-8")
    except Exception:
        pass  # logging must never break a send


# ---------------------------------------------------------------------------
# Send / reply
# ---------------------------------------------------------------------------

def _auto_confirm_ok(*recipient_lists: list[str] | None) -> bool:
    """True when every recipient is on the auto-confirm allowlist.

    Recipients may be bare addresses or "Name <addr>" forms. An empty
    allowlist or an empty recipient set never auto-confirms.
    """
    allow = set(settings.auto_confirm_recipients)
    if not allow:
        return False
    recipients = [r for lst in recipient_lists for r in (lst or [])]
    if not recipients:
        return False
    return all(
        (parseaddr(r)[1] or r).strip().lower() in allow for r in recipients
    )


_profile_email_cache: str | None = None


def _profile_email(svc) -> str:
    """The authenticated account's address, cached for the process lifetime."""
    global _profile_email_cache
    if not _profile_email_cache:
        _profile_email_cache = (
            svc.users().getProfile(userId="me").execute().get("emailAddress", "")
        )
    return _profile_email_cache


def send_message(req: SendRequest) -> dict[str, Any]:
    if not req.confirm and not _auto_confirm_ok(req.to, req.cc, req.bcc):
        return _preview(req.to, req.subject, req.body, req.cc, req.bcc, req.html)
    svc = gmail_service()
    # Custom From: display name and/or verified send-as alias. With no alias,
    # the account's own address carries the display name (Gmail keeps the name
    # when the address matches the authenticated account).
    from_addr = None
    if req.send_as or req.from_name:
        addr = (req.send_as or "").strip() or _profile_email(svc)
        from_addr = formataddr((req.from_name, addr)) if req.from_name else addr
    try:
        msg = _build_mime(
            to=req.to, subject=req.subject, body=req.body,
            cc=req.cc, bcc=req.bcc, html=req.html, reply_to=req.reply_to,
            from_addr=from_addr, attachments=req.attachments,
        )
    except ValueError as e:
        return {"sent": False, "error": "attachment_error", "message": str(e)}
    sent = svc.users().messages().send(userId="me", body={"raw": _raw(msg)}).execute()
    _log_sent("send", {"id": sent.get("id"), "to": req.to, "subject": req.subject, "from": from_addr, "attachments": req.attachments})
    return {"sent": True, "id": sent.get("id"), "thread_id": sent.get("threadId"), "to": req.to, "subject": req.subject, "from": from_addr, "attachments": req.attachments}


def reply_message(req: ReplyRequest) -> dict[str, Any]:
    svc = gmail_service()
    thread = svc.users().threads().get(userId="me", id=req.thread_id, format="metadata").execute()
    msgs = thread.get("messages", [])
    if not msgs:
        return {"error": "empty_thread", "message": f"No messages in thread {req.thread_id}."}
    last = msgs[-1]
    headers = {h["name"].lower(): h["value"] for h in last.get("payload", {}).get("headers", [])}

    subject = headers.get("subject", "")
    if subject and not subject.lower().startswith("re:"):
        subject = f"Re: {subject}"
    # Reply goes to whoever sent the last message; reply_all adds the original recipients.
    to = [headers.get("reply-to") or headers.get("from", "")]
    to = [t for t in to if t]
    cc = list(req.cc)
    if req.reply_all and headers.get("cc"):
        cc.extend([c.strip() for c in headers["cc"].split(",") if c.strip()])

    if not req.confirm and not _auto_confirm_ok(to, cc):
        prev = _preview(to, subject, req.body, cc, html=req.html, thread_id=req.thread_id)
        prev["replying_to"] = {"from": headers.get("from"), "subject": headers.get("subject")}
        return prev

    extra = {
        "In-Reply-To": headers.get("message-id", ""),
        "References": headers.get("references", "") + " " + headers.get("message-id", ""),
    }
    msg = _build_mime(to=to, subject=subject, body=req.body, cc=cc, html=req.html, extra_headers=extra)
    sent = svc.users().messages().send(
        userId="me", body={"raw": _raw(msg), "threadId": req.thread_id}
    ).execute()
    _log_sent("reply", {"id": sent.get("id"), "thread_id": req.thread_id, "to": to, "subject": subject})
    return {"sent": True, "id": sent.get("id"), "thread_id": sent.get("threadId"), "to": to, "subject": subject}


# ---------------------------------------------------------------------------
# Drafts
# ---------------------------------------------------------------------------

def create_draft(req: DraftCreateRequest) -> dict[str, Any]:
    msg = _build_mime(
        to=req.to, subject=req.subject, body=req.body,
        cc=req.cc, bcc=req.bcc, html=req.html,
    )
    body: dict[str, Any] = {"message": {"raw": _raw(msg)}}
    if req.thread_id:
        body["message"]["threadId"] = req.thread_id
    svc = gmail_service()
    draft = svc.users().drafts().create(userId="me", body=body).execute()
    return {
        "created": True,
        "draft_id": draft.get("id"),
        "message_id": draft.get("message", {}).get("id"),
        "to": req.to,
        "subject": req.subject,
        "note": "Review in Gmail's Drafts, or send via POST /drafts/send with confirm=true.",
    }


def list_drafts(max_results: int = 20) -> dict[str, Any]:
    svc = gmail_service()
    resp = svc.users().drafts().list(userId="me", maxResults=max_results).execute()
    out = []
    for d in resp.get("drafts", []):
        full = svc.users().drafts().get(userId="me", id=d["id"], format="metadata").execute()
        headers = {h["name"].lower(): h["value"] for h in full.get("message", {}).get("payload", {}).get("headers", [])}
        out.append({
            "draft_id": d["id"],
            "to": headers.get("to"),
            "subject": headers.get("subject"),
            "snippet": full.get("message", {}).get("snippet"),
        })
    return {"count": len(out), "drafts": out}


def send_draft(draft_id: str, confirm: bool) -> dict[str, Any]:
    if not confirm:
        return {
            "sent": False,
            "preview": True,
            "draft_id": draft_id,
            "instruction": "Call /drafts/send again with confirm=true to send this draft.",
        }
    svc = gmail_service()
    sent = svc.users().drafts().send(userId="me", body={"id": draft_id}).execute()
    _log_sent("draft_send", {"id": sent.get("id"), "draft_id": draft_id})
    return {"sent": True, "id": sent.get("id"), "thread_id": sent.get("threadId"), "draft_id": draft_id}


def delete_draft(draft_id: str) -> dict[str, Any]:
    svc = gmail_service()
    svc.users().drafts().delete(userId="me", id=draft_id).execute()
    return {"deleted": True, "draft_id": draft_id}


# ---------------------------------------------------------------------------
# Read / search
# ---------------------------------------------------------------------------

def _header(payload: dict[str, Any], name: str) -> str | None:
    for h in payload.get("headers", []):
        if h["name"].lower() == name.lower():
            return h["value"]
    return None


def _decode_part(data: str) -> str:
    return base64.urlsafe_b64decode(data.encode()).decode("utf-8", errors="replace")


def _extract_body(payload: dict[str, Any]) -> str:
    mime = payload.get("mimeType", "")
    if mime.startswith("text/plain") and payload.get("body", {}).get("data"):
        return _decode_part(payload["body"]["data"])
    # Walk multipart, prefer text/plain, fall back to text/html (stripped).
    plain, html = "", ""
    for part in payload.get("parts", []) or []:
        sub = _extract_body(part)
        if part.get("mimeType", "").startswith("text/plain") and sub:
            plain = plain or sub
        elif part.get("mimeType", "").startswith("text/html") and sub:
            html = html or sub
    if plain:
        return plain
    if html:
        return re.sub(r"<[^>]+>", " ", html)
    if payload.get("body", {}).get("data"):
        return _decode_part(payload["body"]["data"])
    return ""


def search_messages(q: str | None, max_results: int, label_ids: list[str] | None = None) -> dict[str, Any]:
    svc = gmail_service()
    n = max(1, min(max_results, settings.max_search_results))
    resp = svc.users().messages().list(
        userId="me", q=q or "", maxResults=n, labelIds=label_ids or None
    ).execute()
    out = []
    for ref in resp.get("messages", []):
        m = svc.users().messages().get(userId="me", id=ref["id"], format="metadata",
                                        metadataHeaders=["From", "To", "Subject", "Date"]).execute()
        payload = m.get("payload", {})
        out.append({
            "id": m["id"],
            "thread_id": m.get("threadId"),
            "from": _header(payload, "From"),
            "to": _header(payload, "To"),
            "subject": _header(payload, "Subject"),
            "date": _header(payload, "Date"),
            "snippet": m.get("snippet"),
            "labels": m.get("labelIds", []),
            "unread": "UNREAD" in m.get("labelIds", []),
        })
    return {"query": q, "count": len(out), "messages": out}


def get_message(message_id: str) -> dict[str, Any]:
    svc = gmail_service()
    m = svc.users().messages().get(userId="me", id=message_id, format="full").execute()
    payload = m.get("payload", {})
    body = _extract_body(payload)
    return {
        "id": m["id"],
        "thread_id": m.get("threadId"),
        "from": _header(payload, "From"),
        "to": _header(payload, "To"),
        "cc": _header(payload, "Cc"),
        "subject": _header(payload, "Subject"),
        "date": _header(payload, "Date"),
        "labels": m.get("labelIds", []),
        "unread": "UNREAD" in m.get("labelIds", []),
        "body": body[: settings.body_snippet_chars],
        "body_truncated": len(body) > settings.body_snippet_chars,
    }


def get_thread(thread_id: str) -> dict[str, Any]:
    svc = gmail_service()
    t = svc.users().threads().get(userId="me", id=thread_id, format="full").execute()
    msgs = []
    for m in t.get("messages", []):
        payload = m.get("payload", {})
        body = _extract_body(payload)
        msgs.append({
            "id": m["id"],
            "from": _header(payload, "From"),
            "subject": _header(payload, "Subject"),
            "date": _header(payload, "Date"),
            "labels": m.get("labelIds", []),
            "body": body[: settings.body_snippet_chars],
        })
    return {"thread_id": thread_id, "count": len(msgs), "messages": msgs}


# ---------------------------------------------------------------------------
# Labels & modify
# ---------------------------------------------------------------------------

def list_labels() -> dict[str, Any]:
    svc = gmail_service()
    resp = svc.users().labels().list(userId="me").execute()
    labels = [{"id": l["id"], "name": l["name"], "type": l.get("type")} for l in resp.get("labels", [])]
    return {"count": len(labels), "labels": labels}


def create_label(name: str) -> dict[str, Any]:
    svc = gmail_service()
    label = svc.users().labels().create(
        userId="me",
        body={"name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show"},
    ).execute()
    return {"created": True, "id": label["id"], "name": label["name"]}


def modify_labels(message_id: str, add: list[str], remove: list[str]) -> dict[str, Any]:
    svc = gmail_service()
    m = svc.users().messages().modify(
        userId="me", id=message_id, body={"addLabelIds": add, "removeLabelIds": remove}
    ).execute()
    return {"id": m["id"], "labels": m.get("labelIds", []), "added": add, "removed": remove}


def mark_read(message_id: str, read: bool = True) -> dict[str, Any]:
    return modify_labels(message_id, add=[] if read else ["UNREAD"], remove=["UNREAD"] if read else [])


def archive(message_id: str) -> dict[str, Any]:
    return modify_labels(message_id, add=[], remove=["INBOX"])


def trash(message_id: str) -> dict[str, Any]:
    svc = gmail_service()
    svc.users().messages().trash(userId="me", id=message_id).execute()
    return {"trashed": True, "id": message_id, "note": "Moved to Trash (recoverable for 30 days)."}


def profile() -> dict[str, Any]:
    svc = gmail_service()
    p = svc.users().getProfile(userId="me").execute()
    return {
        "email": p.get("emailAddress"),
        "messages_total": p.get("messagesTotal"),
        "threads_total": p.get("threadsTotal"),
    }
