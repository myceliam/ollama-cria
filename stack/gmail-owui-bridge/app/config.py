from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

# ═══════════════════════════════════════════════════════════════════════════
# ✏️  AUTO-CONFIRM ALLOWLIST — edit this list to add/remove addresses.
#
# Sends where EVERY recipient (to + cc + bcc) is on this list skip the
# confirm-then-send guard and go out on the FIRST call, even with
# confirm=false. Any recipient NOT on the list still requires confirm=true.
# This keeps prompt-injection/exfiltration protection for strangers while
# making self-sends (briefings etc.) one-shot.
#
# Optional override: set env var AUTO_CONFIRM_RECIPIENTS (comma-separated)
# in .env to replace this list without touching code.
# NOTE: after ANY change here, rebuild the container:
#   docker compose up -d --build   (code is baked into the image, not mounted)
# ═══════════════════════════════════════════════════════════════════════════
AUTO_CONFIRM_RECIPIENTS = [
    "lrooney234@gmail.com",
    "petal1968@gmail.com",
    "myceliam234@gmail.com",
]


@dataclass(frozen=True)
class Settings:
    app_name: str = os.getenv("APP_NAME", "Gmail OWUI Bridge")
    data_dir: Path = Path(os.getenv("DATA_DIR", "/data"))
    google_client_secret_file: Path = Path(
        os.getenv("GOOGLE_CLIENT_SECRET_FILE", "/app/secrets/gcp-oauthkeys.json")
    )
    # Gmail gets its OWN token file (separate scope from the calendar bridge).
    google_token_file: Path = Path(os.getenv("GOOGLE_TOKEN_FILE", "/data/gmail_token.json"))
    oauth_redirect_uri: str = os.getenv(
        "OAUTH_REDIRECT_URI", "http://127.0.0.1:18101/auth/callback"
    )
    api_key: str | None = os.getenv("GMAIL_BRIDGE_API_KEY") or None

    # Auto-confirm allowlist (see banner comment above). Env var wins if set.
    auto_confirm_recipients: tuple[str, ...] = tuple(
        a.strip().lower()
        for a in (
            os.getenv("AUTO_CONFIRM_RECIPIENTS")
            or ",".join(AUTO_CONFIRM_RECIPIENTS)
        ).split(",")
        if a.strip()
    )

    # Sender identity. "me" tells Gmail to use the authenticated account.
    default_sender: str = os.getenv("DEFAULT_SENDER", "me")

    # Read defaults — keep result sets small so small models don't choke.
    default_search_max: int = int(os.getenv("DEFAULT_SEARCH_MAX", "15"))
    max_search_results: int = int(os.getenv("MAX_SEARCH_RESULTS", "100"))
    body_snippet_chars: int = int(os.getenv("BODY_SNIPPET_CHARS", "4000"))

    # Attachments: only files under these roots may be attached (path-traversal /
    # secret-exfil guard), each capped at max_attachment_bytes.
    attachment_allowed_dirs: tuple[str, ...] = tuple(
        d.strip()
        for d in os.getenv("ATTACHMENT_ALLOWED_DIRS", "/workspace,/data").split(",")
        if d.strip()
    )
    max_attachment_bytes: int = int(os.getenv("MAX_ATTACHMENT_BYTES", str(20 * 1024 * 1024)))

    @property
    def oauth_state_file(self) -> Path:
        return self.data_dir / "gmail_oauth_state.txt"

    @property
    def sent_log_file(self) -> Path:
        return self.data_dir / "gmail_sent_log.json"


settings = Settings()
settings.data_dir.mkdir(parents=True, exist_ok=True)
