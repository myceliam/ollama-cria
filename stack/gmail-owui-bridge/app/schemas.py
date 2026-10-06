from __future__ import annotations

from pydantic import BaseModel, Field, field_validator


def _clean_emails(value: list[str]) -> list[str]:
    return [e.strip() for e in value if e and e.strip()]


class SendRequest(BaseModel):
    to: list[str] = Field(min_length=1, description="Recipient email addresses.")
    subject: str = Field(default="", max_length=2048)
    body: str = Field(default="", description="Plain-text body (or HTML if html=true).")
    cc: list[str] = Field(default_factory=list)
    bcc: list[str] = Field(default_factory=list)
    html: bool = Field(default=False, description="Treat body as HTML.")
    reply_to: str | None = Field(default=None, description="Optional Reply-To header.")
    from_name: str | None = Field(
        default=None,
        description="Optional display name for the From header, e.g. '📰 Daily Briefings'. "
        "Shown by inboxes in place of the bare account name.",
    )
    send_as: str | None = Field(
        default=None,
        description="Optional From address. MUST be a verified Gmail 'Send mail as' alias of the "
        "authenticated account, otherwise Gmail silently rewrites it back to the account address.",
    )
    confirm: bool = Field(
        default=False,
        description="Must be true to actually SEND. When false, returns a preview only and sends nothing.",
    )
    attachments: list[str] = Field(
        default_factory=list,
        description="Absolute paths of files to attach, e.g. ['/workspace/chart.png']. Each must live "
        "under an allowed directory (ATTACHMENT_ALLOWED_DIRS, default /workspace,/data).",
    )

    @field_validator("to", "cc", "bcc")
    @classmethod
    def _trim(cls, value: list[str]) -> list[str]:
        return _clean_emails(value)


class ReplyRequest(BaseModel):
    thread_id: str = Field(description="Gmail thread ID to reply within (from search/get).")
    body: str = Field(description="Plain-text body (or HTML if html=true).")
    html: bool = False
    reply_all: bool = Field(default=False, description="CC everyone on the latest message in the thread.")
    cc: list[str] = Field(default_factory=list)
    confirm: bool = Field(
        default=False,
        description="Must be true to actually SEND the reply. When false, returns a preview only.",
    )

    @field_validator("cc")
    @classmethod
    def _trim(cls, value: list[str]) -> list[str]:
        return _clean_emails(value)


class DraftCreateRequest(BaseModel):
    to: list[str] = Field(default_factory=list)
    subject: str = Field(default="", max_length=2048)
    body: str = ""
    cc: list[str] = Field(default_factory=list)
    bcc: list[str] = Field(default_factory=list)
    html: bool = False
    thread_id: str | None = Field(default=None, description="Attach the draft to an existing thread (for replies).")

    @field_validator("to", "cc", "bcc")
    @classmethod
    def _trim(cls, value: list[str]) -> list[str]:
        return _clean_emails(value)


class DraftSendRequest(BaseModel):
    draft_id: str
    confirm: bool = Field(default=False, description="Must be true to actually send the existing draft.")


class IdRequest(BaseModel):
    id: str


class ModifyLabelsRequest(BaseModel):
    id: str = Field(description="Message ID to modify.")
    add_label_ids: list[str] = Field(default_factory=list)
    remove_label_ids: list[str] = Field(default_factory=list)


class CreateLabelRequest(BaseModel):
    name: str = Field(min_length=1, max_length=225)
