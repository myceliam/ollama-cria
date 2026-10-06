# Gmail OWUI Bridge 📬

A small FastAPI service that exposes your Gmail to Open WebUI as an OpenAPI tool —
send, reply, read, search, manage drafts, and apply labels — with a
**confirm-then-send** safety guard so the model can never fire off an email without
an explicit confirm step.

This is the sibling of `gcal-owui-bridge` and reuses **the same Desktop Google OAuth
client**. Runs on the PC next to OWUI (binds `127.0.0.1:18101`), so no VPS / HTTPS /
Tailscale routing is needed.

---

## What it does

| Area | Endpoints |
|---|---|
| 📤 Send | `POST /messages/send`, `POST /messages/reply` (both confirm-then-send) |
| 📝 Drafts | `POST /drafts/create`, `GET /drafts`, `POST /drafts/send`, `POST /drafts/delete` |
| 📥 Read | `GET /messages/search`, `GET /messages/get`, `GET /threads/get` |
| 🏷️ Labels | `GET /labels`, `POST /labels/create`, `POST /messages/modify`, `/messages/mark_read`, `/messages/archive`, `/messages/trash` |
| ⚙️ System | `GET /health`, `GET /profile`, `GET /auth/*` |

**Scope:** a single `https://www.googleapis.com/auth/gmail.modify`. That covers
everything above. It deliberately does **not** grant permanent (bypass-Trash)
deletion — `/messages/trash` moves to Trash only.

**Is it free?** Yes. The Gmail API has no cost within a daily quota of 80,000,000
units/project — sending costs 100 units each, so ~800k sends/day before any charge
could apply. Free Gmail accounts also cap sending at 500 emails/day per address.
You will never get near either limit for personal use.

---

## Confirm-then-send 🛡️

`/messages/send`, `/messages/reply`, and `/drafts/send` all require `confirm: true`.

- Call with `confirm: false` (the default) → returns a **preview** (to/cc/subject/body)
  and sends nothing.
- The model shows you the preview, you say yes → it calls again with `confirm: true`.

This is the safety net against a model sending a wrong or hallucinated email.

---

## One-time setup

### 1. Enable the Gmail API
In Google Cloud Console → the **same project** your calendar OAuth client lives in →
*APIs & Services → Library → Gmail API → Enable*. (The Calendar API is already on;
this just adds Gmail to the same project.)

### 2. Configure env
```powershell
cd E:\ai\ollama\gmail-owui-bridge
copy .env.example .env
# Edit .env and set GMAIL_BRIDGE_API_KEY to a long random string.
```
No new OAuth client needed — `../secrets/gcp-oauthkeys.json` (your Desktop client) is
mounted read-only, exactly like the calendar bridge.

### 3. Build & start (from PowerShell)
```powershell
docker compose up -d --build
```

### 4. Authorise Gmail (one browser round-trip)
Gmail needs its own token because the calendar token only holds the calendar scope.
```powershell
# Get the consent URL (sends your API key):
curl.exe -s -H "X-API-Key: <your-key>" http://127.0.0.1:18101/auth/url
```
Open the returned `authorization_url` in a browser, approve the Gmail permission, and
you'll land on `/auth/callback` showing "Gmail authorised ✅". A `gmail_token.json` is
written to `./data`.

> ⚠️ While the OAuth app is in **Testing** mode the token expires after 7 days. Publish
> the app in Google Cloud Console to stop weekly re-auth — same note as the gcal bridge.

### 5. Add the tool in Open WebUI
Admin → Settings → Tools → add an OpenAPI tool server:
- URL: `http://host.docker.internal:18101/openapi.json`
- Auth: Bearer (or X-API-Key) = your `GMAIL_BRIDGE_API_KEY`

(If OWUI's API-key endpoint restrictions block it, allow these paths or disable the
restriction, same gotcha as the calendar bridge.)

---

## Quick test
```powershell
.\check.ps1            # health + auth status
# Preview a send (sends nothing):
curl.exe -s -X POST http://127.0.0.1:18101/messages/send `
  -H "X-API-Key: <your-key>" -H "Content-Type: application/json" `
  -d '{\"to\":[\"you@example.com\"],\"subject\":\"test\",\"body\":\"hello\"}'
# Same call with "confirm": true actually sends.
```

## Gmail search cheatsheet
`/messages/search?q=` accepts normal Gmail operators:
`is:unread`, `from:bank`, `to:me`, `subject:invoice`, `newer_than:7d`, `has:attachment`,
`label:work`, `in:inbox`. Combine freely: `from:hmrc is:unread newer_than:30d`.
