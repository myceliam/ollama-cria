# Home Lab Status Dashboard v2.0

Self-hosted, lightweight status dashboard for a Tailscale mesh network.  
Monitors 8 nodes via async ICMP ping + TCP port 22 checks, with historical analytics powered by SQLite, interactive Chart.js time-series, and a glassmorphism drill-down modal.

---

## What's New in v2.0

| Feature | Description |
|---|---|
| **SQLite Persistence** | Every 15-second check is saved to `metrics.db` — no data lost on restart |
| **Global Line Chart** | Chart.js-powered latency over time, with interactive legend toggles |
| **Timeframe Filters** | Toggle between 1 Hour, 24 Hours, and 7 Days of historical data |
| **Node Sparklines** | Each card shows a mini line chart of the last 60 minutes |
| **Drill-Down Modal** | Click any card → beautiful glassmorphism modal with SVG latency gauge, 7-day GitHub-style heatmap, and full stats |
| **Auto Cleanup** | Records older than 30 days are pruned automatically every hour |

---

## Quick Start (Docker Compose)

```bash
# 1. Build the image and start the container
docker compose up -d --build

# 2. Open your browser
#    http://localhost:6080
```

The dashboard will start probing immediately. Historical data accumulates automatically — the chart will populate as checks roll in.

---

## Project Structure

```
.
├── main.py              # FastAPI app entry point, routes, lifespan
├── monitor.py           # Async ICMP + TCP checks, background scheduler, DB persistence
├── database.py          # Async SQLite layer — init, insert, prune, history, node detail
├── requirements.txt     # Python dependencies (fastapi, uvicorn, aiosqlite)
├── static/
│   └── index.html       # Single-page dashboard (Tailwind CDN, Chart.js CDN, vanilla JS)
├── Dockerfile           # Multi-stage secure build
├── docker-compose.yml   # One-command deployment
└── README.md
```

---

## API Reference

| Endpoint | Method | Description |
|---|---|---|
| `/` | GET | Serves the dashboard HTML |
| `/api/status` | GET | Real-time snapshot of all 8 nodes |
| `/api/history?timeframe=1h\|24h\|7d` | GET | Aggregated time-series for the global chart |
| `/api/node/{node_id}` | GET | Deep metrics: stats, heatmap, current status |

### `/api/status` Response

```json
{
  "nodes": [
    {
      "id": "kais-pc", "name": "Kai's PC",
      "tailscale_ip": "{{KAIS_PC_TS_IP}}", "magicdns": "{{KAIS_PC_TS_NAME}}",
      "status": "online", "latency_ms": 12.4, "port_22": true,
      "last_checked": "2026-07-15T14:30:00+00:00"
    }
  ],
  "last_update": "2026-07-15T14:30:15+00:00",
  "refresh_interval_seconds": 15
}
```

### `/api/history?timeframe=24h` Response

```json
{
  "timeframe": "24h",
  "lookback": "24 hours",
  "datasets": [
    {
      "id": "kais-pc", "name": "Kai's PC", "color": "#ff006e",
      "data": [
        {"x": "2026-07-15T12:00:00", "y": 12.4, "online": true}
      ]
    }
  ]
}
```

### `/api/node/kais-pc` Response

```json
{
  "id": "kais-pc", "name": "Kai's PC",
  "tailscale_ip": "{{KAIS_PC_TS_IP}}", "magicdns": "{{KAIS_PC_TS_NAME}}",
  "color": "#ff006e",
  "current": { "status": "online", "latency_ms": 12.4, "port_22": true, "last_checked": "..." },
  "stats": {
    "total_checks": 40320, "uptime_pct": 99.98, "avg_latency": 15.2,
    "max_latency": 245.0, "min_latency": 3.1, "packet_loss_pct": 0.02,
    "downtime_incidents": 3, "last_seen": "..."
  },
  "heatmap": [
    { "day": "Sun", "hours": [{"hour": 0, "online": true, "ratio": 1.0}, ...] }
  ]
}
```

---

## Running Without Docker

```bash
# 1. Create a virtual environment
python3 -m venv venv && source venv/bin/activate   # Linux/macOS
python -m venv venv && venv\Scripts\activate        # Windows

# 2. Install dependencies
pip install -r requirements.txt

# 3. Run
uvicorn main:app --host 0.0.0.0 --port 8000
```

> **Note:** ICMP pings use the system `ping` binary. On Linux, you may need `setcap cap_net_raw+ep` on the `ping` binary or run as root.

---

## How Monitoring Works

Each node is checked with **two probes** every 15 seconds:

| Probe | Method | Timeout |
|---|---|---|
| ICMP Ping | System `ping` via `asyncio.create_subprocess_exec` | 2 s |
| TCP Connect | `asyncio.open_connection` to port 22 (Tailscale SSH) | 3 s |

A node is **online** if **either** probe succeeds. Every result is persisted to `metrics.db`.

### Data Aggregation

| Timeframe | Bucket Size | Approx. Points/Node |
|---|---|---|
| 1 Hour | Raw (no aggregation) | ~240 |
| 24 Hours | 5-minute buckets | ~288 |
| 7 Days | 10-minute buckets | ~1,008 |

### Data Retention

A background cleanup task runs every hour and deletes records older than **30 days**.

---

## Customizing

### Add / Remove Nodes

Edit the `TARGETS` list in `monitor.py` and the `NODE_COLORS` dict in both `database.py` and `static/index.html`:

```python
TARGETS: list[Target] = [
    Target("my-node", "My Node", "100.x.x.x", "my-node.{{TS_DOMAIN}}"),
]
```

Rebuild: `docker compose up -d --build`

### Change Port

Edit the `command` and `ports` in `docker-compose.yml`, and update `EXPOSE` / `HEALTHCHECK` in `Dockerfile`.

### Change Refresh Interval

Update `scheduler_loop(interval=...)` in `main.py`, and update `REFRESH_INTERVAL` in `static/index.html`.

---

## License

MIT