"""
Home Lab Status Dashboard — FastAPI application entry point.
"""
import asyncio
import logging
import sys
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Query
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse

from monitor import scheduler_loop, cleanup_loop, get_all_statuses
import database

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("dashboard")

# ---------------------------------------------------------------------------
# Lifespan — start / stop the background schedulers
# ---------------------------------------------------------------------------
_scheduler_task: asyncio.Task | None = None
_cleanup_task: asyncio.Task | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Start background monitor + cleanup loops on startup, cancel on shutdown."""
    global _scheduler_task, _cleanup_task

    # Initialise the SQLite database
    await database.init_db()

    logger.info("Starting background monitor scheduler…")
    _scheduler_task = asyncio.create_task(scheduler_loop(interval=15))
    _cleanup_task = asyncio.create_task(cleanup_loop(interval=3600, retention_days=30))

    try:
        yield
    finally:
        for task, name in ((_scheduler_task, "scheduler"), (_cleanup_task, "cleanup")):
            if task:
                task.cancel()
                try:
                    await task
                except asyncio.CancelledError:
                    pass
        logger.info("All background tasks stopped.")


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------
app = FastAPI(
    title="Home Lab Status Dashboard",
    version="2.0.0",
    lifespan=lifespan,
)

# Mount static files
static_dir = Path(__file__).parent / "static"
if static_dir.is_dir():
    app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------
@app.get("/api/status")
async def api_status():
    """Return the latest status snapshot for every monitored node."""
    return await get_all_statuses()


@app.get("/api/history")
async def api_history(timeframe: str = Query("24h", regex="^(1h|24h|7d)$")):
    """Return aggregated time-series data for the global line chart."""
    return await database.get_history(timeframe)


@app.get("/api/node/{node_id}")
async def api_node_detail(node_id: str):
    """Return deep metrics for a single machine (stats, heatmap, current status)."""
    data = await database.get_node_detail(node_id)
    if not data:
        from fastapi.responses import JSONResponse
        return JSONResponse(status_code=404, content={"detail": "Node not found"})
    return data


@app.get("/")
async def serve_dashboard():
    """Serve the single-page dashboard."""
    index_path = static_dir / "index.html"
    if index_path.is_file():
        return FileResponse(index_path)
    return {"message": "Dashboard static files not found. Place index.html in static/"}