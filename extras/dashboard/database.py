"""
Async SQLite persistence layer for the Home Lab Status Dashboard.

Stores every check result so the frontend can render time-series charts,
heatmaps, and compute aggregate statistics (uptime %, avg latency, etc.).
"""
import asyncio
import logging
import os
from datetime import datetime, timezone
from typing import Optional

import aiosqlite

from monitor import TARGETS, NodeStatus

logger = logging.getLogger(__name__)

DB_DIR = os.environ.get("DB_DIR", os.path.join(os.path.dirname(__file__), "data"))
DB_PATH = os.path.join(DB_DIR, "metrics.db")

# Ensure the data directory exists so the non-root user can create the DB
os.makedirs(DB_DIR, exist_ok=True)

# ---------------------------------------------------------------------------
# Initialisation
# ---------------------------------------------------------------------------
async def init_db() -> None:
    """Create the metrics table and supporting indexes if they don't exist."""
    async with aiosqlite.connect(DB_PATH) as db:
        await db.execute("""
            CREATE TABLE IF NOT EXISTS metrics (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id    TEXT    NOT NULL,
                node_name  TEXT    NOT NULL,
                tailscale_ip TEXT   NOT NULL,
                magicdns   TEXT    NOT NULL,
                status     TEXT    NOT NULL,          -- 'online' | 'offline'
                latency_ms REAL,                     -- NULL when offline
                port_22    INTEGER NOT NULL,          -- 0 | 1
                timestamp  TEXT    NOT NULL           -- ISO-8601 UTC
            )
        """)
        await db.execute("""
            CREATE INDEX IF NOT EXISTS idx_node_ts
                ON metrics (node_id, timestamp)
        """)
        await db.commit()
    logger.info("Database initialised at %s", DB_PATH)


# ---------------------------------------------------------------------------
# Insert
# ---------------------------------------------------------------------------
async def insert_metrics(nodes: list[NodeStatus]) -> None:
    """Persist one snapshot of every monitored node."""
    now = datetime.now(timezone.utc).isoformat()
    rows = [
        (
            n.id,
            n.name,
            n.tailscale_ip,
            n.magicdns,
            n.status,
            n.latency_ms,
            1 if n.port_22 else 0,
            now,
        )
        for n in nodes
    ]
    try:
        async with aiosqlite.connect(DB_PATH) as db:
            await db.executemany(
                """INSERT INTO metrics
                   (node_id, node_name, tailscale_ip, magicdns, status, latency_ms, port_22, timestamp)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                rows,
            )
            await db.commit()
    except Exception:
        logger.exception("Failed to insert metrics batch")


# ---------------------------------------------------------------------------
# Pruning
# ---------------------------------------------------------------------------
async def prune_old_data(retention_days: int = 30) -> int:
    """Remove records older than *retention_days*. Returns the number of deleted rows."""
    try:
        async with aiosqlite.connect(DB_PATH) as db:
            cursor = await db.execute(
                "DELETE FROM metrics WHERE timestamp < datetime('now', ?)",
                (f"-{retention_days} days",),
            )
            await db.commit()
            deleted = cursor.rowcount
            if deleted:
                logger.info("Pruned %d old metrics rows", deleted)
            return deleted
    except Exception:
        logger.exception("Pruning failed")
        return 0


# ---------------------------------------------------------------------------
# History — time-series for the global chart
# ---------------------------------------------------------------------------
async def get_history(timeframe: str = "24h") -> dict:
    """
    Return aggregated time-series data for every node.

    *timeframe* values:
      - ``1h``  → raw data,     last 1 hour    (~240 points/node)
      - ``24h`` → 5-min buckets, last 24 hours  (~288 points/node)
      - ``7d``  → 10-min buckets,last 7 days    (~1008 points/node)
    """
    if timeframe == "1h":
        lookback = "-1 hour"
        bucket = None  # raw data
    elif timeframe == "7d":
        lookback = "-7 days"
        bucket = "10 minutes"
    else:  # default 24h
        lookback = "24 hours"
        bucket = "5 minutes"

    # Build a query that optionally groups by time buckets
    if bucket:
        # SQLite strftime with bucket intervals
        select_ts = (
            f"datetime(strftime('%s', timestamp) / ({_bucket_seconds(bucket)}) * "
            f"{_bucket_seconds(bucket)}, 'unixepoch') AS bucket_ts"
        )
        group_clause = "GROUP BY node_id, bucket_ts"
    else:
        select_ts = "timestamp AS bucket_ts"
        group_clause = ""

    query = f"""
        SELECT
            node_id,
            node_name,
            {select_ts},
            MAX(timestamp) AS latest_ts,
            AVG(latency_ms) AS avg_latency,
            SUM(CASE WHEN status = 'online' THEN 1 ELSE 0 END) AS online_count,
            COUNT(*) AS total_count
        FROM metrics
        WHERE timestamp >= datetime('now', ?)
        {group_clause}
        ORDER BY bucket_ts ASC
    """

    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(query, (f"-{lookback}",))
        rows = await cursor.fetchall()

    # Pivot into per-node arrays for Chart.js
    nodes: dict[str, dict] = {}
    for t in TARGETS:
        nodes[t.id] = {
            "id": t.id,
            "name": t.name,
            "color": NODE_COLORS.get(t.id, "#ffffff"),
            "data": [],
        }

    for row in rows:
        node_id = row["node_id"]
        if node_id in nodes:
            online_ratio = row["online_count"] / max(row["total_count"], 1)
            nodes[node_id]["data"].append({
                "x": row["bucket_ts"],
                "y": round(row["avg_latency"], 2) if row["avg_latency"] is not None else None,
                "online": online_ratio > 0.5,  # majority online in this bucket
            })

    # Sort each node's data by time
    for n in nodes.values():
        n["data"].sort(key=lambda d: d["x"])

    return {
        "timeframe": timeframe,
        "datasets": list(nodes.values()),
        "lookback": lookback.lstrip("-").replace("_", " "),
    }


# ---------------------------------------------------------------------------
# Node detail — deep stats + heatmap for drill-down modal
# ---------------------------------------------------------------------------
async def get_node_detail(node_id: str) -> dict:
    """Return detailed stats and a 7-day hourly heatmap for one node."""
    target = next((t for t in TARGETS if t.id == node_id), None)
    if target is None:
        return {}

    async with aiosqlite.connect(DB_PATH) as db:
        db.row_factory = aiosqlite.Row

        # ── Aggregate stats (last 7 days) ──
        stats = await db.execute(
            """SELECT
                COUNT(*)                                      AS total_checks,
                SUM(CASE WHEN status = 'online' THEN 1 ELSE 0 END) AS online_checks,
                ROUND(AVG(CASE WHEN status = 'online' THEN latency_ms END), 2) AS avg_latency,
                MAX(CASE WHEN status = 'online' THEN latency_ms END) AS max_latency,
                MIN(CASE WHEN status = 'online' THEN latency_ms END) AS min_latency,
                MAX(timestamp) AS last_seen
            FROM metrics
            WHERE node_id = ?
              AND timestamp >= datetime('now', '-7 days')""",
            (node_id,),
        )
        stat_row = await stats.fetchone()

        # ── Downtime incidents (transitions from online → offline) ──
        incidents = await db.execute(
            """SELECT COUNT(*) AS incidents FROM (
                SELECT status,
                       LAG(status) OVER (ORDER BY timestamp) AS prev_status
                FROM metrics
                WHERE node_id = ?
                  AND timestamp >= datetime('now', '-7 days')
            ) WHERE prev_status = 'online' AND status = 'offline'""",
            (node_id,),
        )
        inc_row = await incidents.fetchone()

        # ── Current status (most recent row) ──
        current = await db.execute(
            """SELECT status, latency_ms, port_22, timestamp
               FROM metrics WHERE node_id = ?
               ORDER BY timestamp DESC LIMIT 1""",
            (node_id,),
        )
        cur_row = await current.fetchone()

        # ── 7-day hourly heatmap ──
        heatmap = await db.execute(
            """SELECT
                strftime('%w', timestamp) AS dow,          -- 0=Sun … 6=Sat
                strftime('%H', timestamp) AS hour,
                SUM(CASE WHEN status = 'online' THEN 1 ELSE 0 END) AS online_cnt,
                COUNT(*) AS total
            FROM metrics
            WHERE node_id = ?
              AND timestamp >= datetime('now', '-7 days')
            GROUP BY dow, hour
            ORDER BY dow, hour""",
            (node_id,),
        )
        heatmap_rows = await heatmap.fetchall()

    # Build heatmap grid: 7 days × 24 hours
    heatmap_grid = []
    day_names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    for dow in range(7):
        hour_slots = []
        for hour in range(24):
            # Find matching row
            match = next(
                (r for r in heatmap_rows if int(r["dow"]) == dow and int(r["hour"]) == hour),
                None,
            )
            if match and match["total"] > 0:
                ratio = match["online_cnt"] / match["total"]
                hour_slots.append({
                    "hour": hour,
                    "online": ratio >= 0.5,
                    "ratio": round(ratio, 2),
                })
            else:
                hour_slots.append({"hour": hour, "online": False, "ratio": 0.0})
        heatmap_grid.append({"day": day_names[dow], "hours": hour_slots})

    total = stat_row["total_checks"] or 0
    online = stat_row["online_checks"] or 0

    return {
        "id": node_id,
        "name": target.name,
        "tailscale_ip": target.tailscale_ip,
        "magicdns": target.magicdns,
        "color": NODE_COLORS.get(node_id, "#ffffff"),
        "current": {
            "status": cur_row["status"] if cur_row else "unknown",
            "latency_ms": cur_row["latency_ms"] if cur_row else None,
            "port_22": bool(cur_row["port_22"]) if cur_row else False,
            "last_checked": cur_row["timestamp"] if cur_row else None,
        },
        "stats": {
            "total_checks": total,
            "uptime_pct": round(online / max(total, 1) * 100, 2),
            "avg_latency": stat_row["avg_latency"],
            "max_latency": stat_row["max_latency"],
            "min_latency": stat_row["min_latency"],
            "packet_loss_pct": round((total - online) / max(total, 1) * 100, 2),
            "downtime_incidents": inc_row["incidents"] if inc_row else 0,
            "last_seen": stat_row["last_seen"],
        },
        "heatmap": heatmap_grid,
    }


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Vibrant neon colours for each node (used by both backend and frontend)
NODE_COLORS = {
    "kais-pc":       "#ff006e",  # Hot Pink
    "router":        "#ff8800",  # Electric Orange
    "liams-tab-s10": "#ffdd00",  # Solar Yellow
    "minipc":        "#00f5d4",  # Neon Cyan
    "mr-fold":       "#00bbf9",  # Bright Blue
    "mumspc":        "#9b5de5",  # Vivid Purple
    "pc":            "#00ff88",  # Neon Green
    "vps":           "#ff6b6b",  # Coral
}


def _bucket_seconds(label: str) -> int:
    """Convert a human bucket label like '5 minutes' to integer seconds."""
    parts = label.strip().split()
    num = int(parts[0])
    unit = parts[1].lower()
    if unit in ("s", "sec", "second", "seconds"):
        return num
    if unit in ("m", "min", "minute", "minutes"):
        return num * 60
    if unit in ("h", "hr", "hour", "hours"):
        return num * 3600
    return num * 60  # default to minutes