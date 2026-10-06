# Google Calendar OWUI Bridge

A Dockerised **Open WebUI-ready Google Calendar bridge** with:

- Live Google Calendar reads for accurate current answers.
- Create, update, get, preview-delete, and confirmed-delete event endpoints.
- SQLite cache for local search/change tracking.
- Proper Google Calendar incremental sync using `nextSyncToken`.
- Background refresh loop so events added on your phone are pulled into the local cache.
- FastAPI-generated OpenAPI endpoint for Open WebUI: `/openapi.json`.

## Why this exists

The official Google Calendar MCP is good for live access, but it does not automatically keep a local cache updated. This bridge gives Open WebUI both:

1. **Live window queries** for normal calendar questions.
2. **Incremental cache sync** for tracking changes and local search.

Google Calendar is still the source of truth.

---

## Folder layout

```text
calendar-owui-bridge/
├─ app/
│  ├─ calendar_ops.py
│  ├─ config.py
│  ├─ db.py
│  ├─ google_client.py
│  ├─ main.py
│  └─ schemas.py
├─ data/
│  ├─ client_secret.json     # you add this
│  ├─ token.json             # created after OAuth
│  └─ calendar.sqlite3       # created automatically
├─ .env.example
├─ docker-compose.yml
├─ Dockerfile
├─ requirements.txt
└─ README.md
```

---

## Google Cloud setup

You said you already created the app and added yourself as the sole/test user. For this bridge, make sure your OAuth client has this exact redirect URI:

```text
http://127.0.0.1:18100/auth/callback
```

Download your OAuth client JSON and save it as:

```text
data/client_secret.json
```

If the `data` folder does not exist yet, create it.

---

## Install

From inside the extracted folder:

```powershell
copy .env.example .env
mkdir data
```

Edit `.env` and set a long random API key:

```env
GCAL_BRIDGE_API_KEY="paste-a-long-random-string-here"
```

Then build and run:

```powershell
docker compose up -d --build
```

Check health:

```powershell
curl http://127.0.0.1:18100/health
```

---

## Authorise Google Calendar

Open this in your browser, but include your API key header if calling with curl.

### With curl

```powershell
curl -H "X-API-Key: paste-your-key-here" http://127.0.0.1:18100/auth/url
```

Copy the `authorization_url` into your browser.

After OAuth completes, Google will redirect back to:

```text
http://127.0.0.1:18100/auth/callback
```

You should see a success page.

Then refresh calendars:

```powershell
curl -X POST -H "X-API-Key: paste-your-key-here" http://127.0.0.1:18100/calendars/refresh
```

---

## Add to Open WebUI

Use this OpenAPI URL:

```text
http://host.docker.internal:18100/openapi.json
```

Or, if Open WebUI can reach the host loopback directly:

```text
http://127.0.0.1:18100/openapi.json
```

If Open WebUI lets you set headers for tools, add:

```text
X-API-Key: your-key-from-.env
```

If your Open WebUI container cannot reach `127.0.0.1`, use `host.docker.internal`.

---

## First full sync

This pulls your current calendar list and creates a proper sync token per selected calendar:

```powershell
curl -X POST `
  -H "X-API-Key: paste-your-key-here" `
  -H "Content-Type: application/json" `
  -d "{}" `
  http://127.0.0.1:18100/sync/full
```

After that, incremental sync can run:

```powershell
curl -X POST `
  -H "X-API-Key: paste-your-key-here" `
  -H "Content-Type: application/json" `
  -d "{}" `
  http://127.0.0.1:18100/sync/incremental
```

The container also runs this automatically every `SYNC_INTERVAL_SECONDS` seconds if `ENABLE_BACKGROUND_SYNC=true`.

---

## Recommended Open WebUI instruction

Add this to the system prompt for your calendar-capable model/tool profile:

```text
When the user asks about current or future calendar events, use /events/live rather than memory or cached results. Use Europe/London as the default timezone. For broad calendar questions, query all selected calendars. For deletes, first use /events/delete_preview, show the exact match, and only call /events/delete with confirmed=true if the user clearly confirms the specific event.
```

---

## Useful endpoints

### Live current events

Best endpoint for normal OWUI use:

```text
GET /events/live
```

Example:

```powershell
curl -H "X-API-Key: paste-your-key-here" "http://127.0.0.1:18100/events/live?start=2026-06-23T00:00:00%2B01:00&end=2026-07-23T23:59:59%2B01:00"
```

### Cached search

```text
GET /events/cache/search?q=doctor
```

This searches SQLite. It is useful for history/change tracking, but live queries are better for current/future scheduling because recurring events are expanded by Google during live queries.

### Create event

```powershell
curl -X POST `
  -H "X-API-Key: paste-your-key-here" `
  -H "Content-Type: application/json" `
  -d '{"calendar_id":"primary","title":"Test OWUI bridge","start":"2026-06-25T10:00:00+01:00","end":"2026-06-25T10:15:00+01:00","timezone":"Europe/London","reminder_minutes":30}' `
  http://127.0.0.1:18100/events/create
```

### Update event

```text
POST /events/update
```

Body:

```json
{
  "calendar_id": "primary",
  "event_id": "event-id-here",
  "title": "Updated title",
  "start": "2026-06-25T11:00:00+01:00",
  "end": "2026-06-25T11:30:00+01:00",
  "timezone": "Europe/London"
}
```

### Delete safely

Preview first:

```text
GET /events/delete_preview?query=Test%20OWUI%20bridge
```

Then delete only the exact match:

```json
{
  "calendar_id": "primary",
  "event_id": "event-id-here",
  "confirmed": true
}
```

---

## Important sync detail

The cache sync deliberately uses Google Calendar's `nextSyncToken` pattern.

That means the background cache can notice events added on your phone, but the live endpoint is still the best endpoint for actual calendar answers.

Why? Google Calendar does not allow `timeMin`, `timeMax`, or `orderBy` to be combined with `syncToken`. So this bridge separates the two jobs:

- `/events/live`: query a date window directly from Google.
- `/sync/incremental`: update the local SQLite cache using Google's sync token.

If Google returns `410 Gone`, the bridge clears that calendar's cache and performs a full sync again.

---

## Security defaults

- The service binds to `127.0.0.1:18100` only in `docker-compose.yml`.
- API key is supported via `X-API-Key`.
- Deletes require `confirmed=true`.
- Delete workflow has a preview endpoint.
- All write actions are logged to `/audit`.
- OAuth token is stored in `data/token.json`; do not share this file.

---

## Troubleshooting

### Open WebUI cannot reach it

Use this URL inside Open WebUI:

```text
http://host.docker.internal:18100/openapi.json
```

### OAuth says redirect URI mismatch

Make sure the redirect URI in Google Cloud exactly matches:

```text
http://127.0.0.1:18100/auth/callback
```

No trailing slash.

### Advanced Protection blocks OAuth

Because this is your own OAuth app and you added yourself as the only/test user, it may work. If Google Advanced Protection still blocks it, the safer fallback is to use a secondary Google account and share selected calendars to it.

### Background sync does nothing

Check:

```powershell
curl -H "X-API-Key: paste-your-key-here" http://127.0.0.1:18100/auth/status
curl -H "X-API-Key: paste-your-key-here" http://127.0.0.1:18100/sync/status
```

---

## Strong opinion

Use `/events/live` for OWUI's normal calendar answers. Treat SQLite as a cache and audit layer, not the master calendar. Google Calendar should remain the source of truth.
