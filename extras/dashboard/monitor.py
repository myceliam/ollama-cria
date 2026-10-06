"""
Home Lab Status Monitor — async Tailscale + ICMP ping + TCP port checks.

HARDENED 2026-07-29. Previous version had four defects that caused false
"Offline" readings, most visibly on mobile peers:

  1. SINGLE-PACKET PING. `ping -c 1` meant one dropped ICMP packet showed the
     node as unreachable. Sleepy Android radios drop packets routinely.
     -> now sends PING_COUNT packets and succeeds if ANY reply arrives.

  2. TAILSCALE STATUS FAILED CLOSED. `_get_tailscale_status()` swallowed every
     exception and returned {}, which silently demoted EVERY node to
     ping-only for that cycle. One slow daemon call = a wall of false offlines.
     -> now caches the last good result and reuses it for TS_CACHE_MAX_AGE.

  3. NO HYSTERESIS. Status was recomputed from scratch each cycle, so a single
     bad probe flipped the card. -> a node must fail OFFLINE_THRESHOLD
     consecutive cycles before it is reported offline. Recovery is immediate.

  4. HARDCODED IPs DRIFT. `minipc` pointed at {{STALE_TS_IP}}, which is not on
     the tailnet (real minipc-ubuntu is {{MINIPC_UBUNTU_TS_IP}}); `mumspc` pointed at a
     peer that no longer exists. -> IPs are now resolved live from the daemon
     by MagicDNS name, with the literal below used only as a fallback.
"""
import asyncio
import json
import os
import re
import time
import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Optional

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Tunables
# ---------------------------------------------------------------------------
PING_COUNT = 3          # ICMP packets per probe; ANY reply counts as up
PING_TIMEOUT = 5.0      # seconds, whole ping invocation
PORT_TIMEOUT = 3.0      # seconds, TCP connect
CHECK_PORT = 22         # Tailscale SSH
OFFLINE_THRESHOLD = 3   # consecutive failed cycles before reporting offline
TAILSCALE_STATUS_TIMEOUT = 6.0
TS_CACHE_MAX_AGE = 120.0  # seconds a cached tailscale result stays usable
REFRESH_INTERVAL = 15   # seconds between full sweeps


# ---------------------------------------------------------------------------
# Target definitions
# ---------------------------------------------------------------------------
@dataclass
class Target:
    id: str
    name: str
    tailscale_ip: str   # fallback only — live IP is resolved from the daemon
    magicdns: str


TARGETS: list[Target] = [
    Target("kais-pc",       "Kai's PC",       "{{KAIS_PC_TS_IP}}", "{{KAIS_PC_TS_NAME}}"),
    Target("router",        "Router",         "{{ROUTER_TS_IP}}",  "{{ROUTER_TS_NAME}}"),
    Target("liams-tab-s10", "Liam's Tab S10", "{{LIAMS_TAB_S10_TS_IP}}",   "{{LIAMS_TAB_S10_TS_NAME}}"),
    Target("minipc",        "MiniPC",         "{{MINIPC_UBUNTU_TS_IP}}", "{{MINIPC_UBUNTU_TS_NAME}}"),
    Target("minipc-win",    "MiniPC (Win)",   "{{MINIPC_WINDOWS_TS_IP}}",  "{{MINIPC_WINDOWS_TS_NAME}}"),
    Target("mr-fold",       "Mr. Fold",       "{{MR_FOLD_TS_IP}}",  "{{MR_FOLD_TS_NAME}}"),
    Target("mumspc",        "Mum's PC",       "{{STALE_TS_IP}}",   "mumspc.{{TS_DOMAIN}}"),
    Target("pc",            "PC",             "{{PC_TS_IP}}",  "{{PC_TS_NAME}}"),
    Target("vps",           "VPS",            "{{VPS_TS_IP}}",   "{{VPS_TS_NAME}}"),
]


# ---------------------------------------------------------------------------
# Per-node status snapshot
# ---------------------------------------------------------------------------
@dataclass
class NodeStatus:
    id: str
    name: str
    tailscale_ip: str
    magicdns: str
    status: str = "unknown"            # "online" | "offline" | "degraded"
    latency_ms: Optional[float] = None
    port_22: bool = False
    last_checked: Optional[str] = None
    tailscale_online: bool = False     # what the Tailscale daemon reports
    # --- diagnostics added 2026-07-29 ---
    consecutive_failures: int = 0      # probe cycles failed in a row
    packet_loss_pct: Optional[float] = None
    ip_source: str = "static"          # "daemon" | "static"
    ts_stale: bool = False             # tailscale data came from cache
    known_peer: bool = True            # False = not present on the tailnet
    # --- connection path (added 2026-07-29) -----------------------------------
    # Tailscale reports CurAddr (the live direct endpoint) and Relay (DERP
    # region). CurAddr populated => peers talk directly. Empty but Online =>
    # traffic is going via a DERP relay.
    # For a phone this is effectively a home/away signal: on home WiFi you get a
    # direct LAN endpoint (~8ms); on 4G, carrier NAT usually defeats UDP hole-
    # punching so it relays, adding the round trip to the DERP region.
    conn_path: str = "unknown"         # direct-lan | direct-wan | relay | offline
    conn_addr: Optional[str] = None    # live endpoint when direct
    relay_region: Optional[str] = None # DERP region code, e.g. "lhr", "hel"


_state_lock = asyncio.Lock()
_node_statuses: dict[str, NodeStatus] = {
    t.id: NodeStatus(id=t.id, name=t.name, tailscale_ip=t.tailscale_ip, magicdns=t.magicdns)
    for t in TARGETS
}
_last_update: Optional[str] = None

# consecutive probe failures per node id — drives the hysteresis
_failure_counts: dict[str, int] = {t.id: 0 for t in TARGETS}

_db_module = None


def _get_db():
    """Lazy-import the database module to avoid circular imports."""
    global _db_module
    if _db_module is None:
        import database  # noqa: F811
        _db_module = database
    return _db_module


# ---------------------------------------------------------------------------
# Tailscale daemon — primary source of truth, now with caching
# ---------------------------------------------------------------------------
TAILSCALE_SOCKET = "/var/run/tailscale/tailscaled.sock"
# Written by the host (see Refresh-Tailscale-Status.ps1) - Windows fallback.
TAILSCALE_STATUS_FILE = "/app/data/tailscale-status.json"
TS_FILE_MAX_AGE = 180.0  # seconds before the host file is considered stale


@dataclass
class TailscaleSnapshot:
    """Resolved view of the tailnet: online flags and live IPs, keyed by name."""
    online_by_name: dict[str, bool] = field(default_factory=dict)
    ip_by_name: dict[str, str] = field(default_factory=dict)
    online_by_ip: dict[str, bool] = field(default_factory=dict)
    curaddr_by_name: dict[str, str] = field(default_factory=dict)
    relay_by_name: dict[str, str] = field(default_factory=dict)
    fetched_at: float = 0.0
    ok: bool = False


_ts_cache = TailscaleSnapshot()


def _norm(name: str) -> str:
    """Normalise a MagicDNS name for matching: lowercase, no trailing dot."""
    return (name or "").rstrip(".").lower()


async def _get_tailscale_status() -> tuple[TailscaleSnapshot, bool]:
    """
    Query the local Tailscale daemon.

    Returns ``(snapshot, is_fresh)``.  On failure the last good snapshot is
    returned with ``is_fresh=False`` provided it is younger than
    TS_CACHE_MAX_AGE — this is the fix for the "one slow daemon call marks
    everything offline" bug.  Includes Self as well as Peers.
    """
    global _ts_cache

    raw = None
    try:
        proc = await asyncio.create_subprocess_exec(
            "tailscale", "--socket", TAILSCALE_SOCKET, "status", "--json",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await asyncio.wait_for(
            proc.communicate(), timeout=TAILSCALE_STATUS_TIMEOUT
        )
        if proc.returncode == 0:
            raw = json.loads(stdout.decode("utf-8", errors="replace"))
        else:
            logger.warning("tailscale status exited %d", proc.returncode)
    except FileNotFoundError:
        logger.error("tailscale CLI not found in image — status will rely on ping only")
    except asyncio.TimeoutError:
        logger.warning("tailscale status timed out after %.1fs", TAILSCALE_STATUS_TIMEOUT)
    except json.JSONDecodeError:
        logger.warning("tailscale status returned invalid JSON")
    except Exception as exc:
        logger.warning("tailscale status failed: %s", exc)

    # --- Fallback: status file written by the HOST -------------------------
    # On Windows the tailscaled socket cannot be bind-mounted (it is a named
    # pipe), so the compose mount produces an empty DIRECTORY and the CLI
    # exits 1 every cycle. Refresh-Tailscale-Status.ps1 on the host writes
    # `tailscale status --json` into the mounted data dir instead.
    if raw is None:
        try:
            with open(TAILSCALE_STATUS_FILE, "r", encoding="utf-8") as fh:
                candidate = json.load(fh)
            age = time.time() - os.path.getmtime(TAILSCALE_STATUS_FILE)
            if age <= TS_FILE_MAX_AGE:
                logger.debug("using host status file (%.0fs old)", age)
                raw = candidate
            else:
                logger.warning("host status file is stale (%.0fs) - is the scheduled task running?", age)
        except FileNotFoundError:
            logger.debug("no host status file at %s", TAILSCALE_STATUS_FILE)
        except Exception as exc:
            logger.warning("could not read host status file: %s", exc)

    if raw is None:
        age = time.monotonic() - _ts_cache.fetched_at
        if _ts_cache.ok and age <= TS_CACHE_MAX_AGE:
            logger.info("using cached tailscale status (%.0fs old)", age)
            return _ts_cache, False
        return TailscaleSnapshot(), False

    snap = TailscaleSnapshot(fetched_at=time.monotonic(), ok=True)

    def _absorb(entry: dict, force_online: Optional[bool] = None) -> None:
        if not isinstance(entry, dict):
            return
        dns = _norm(entry.get("DNSName", ""))
        ips = entry.get("TailscaleIPs") or []
        online = entry.get("Online", False) if force_online is None else force_online
        if dns:
            snap.online_by_name[dns] = bool(online)
            if ips:
                snap.ip_by_name[dns] = ips[0]
            cur = entry.get("CurAddr") or ""
            if cur:
                snap.curaddr_by_name[dns] = cur
            relay = entry.get("Relay") or ""
            if relay:
                snap.relay_by_name[dns] = relay
        for ip in ips:
            snap.online_by_ip[ip] = bool(online)

    # Self is always "online" — we are running on it.
    _absorb(raw.get("Self") or {}, force_online=True)
    for peer in (raw.get("Peer") or {}).values():
        _absorb(peer)

    _ts_cache = snap
    logger.debug("tailscale: %d names, %d ips", len(snap.online_by_name), len(snap.online_by_ip))
    return snap, True


# ---------------------------------------------------------------------------
# Low-level probes
# ---------------------------------------------------------------------------
def _is_windows() -> bool:
    import sys
    return sys.platform == "win32"


async def _ping(ip: str) -> tuple[Optional[float], Optional[float]]:
    """
    Send PING_COUNT ICMP packets.

    Returns ``(best_rtt_ms, packet_loss_pct)``.  ``best_rtt_ms`` is None only
    when EVERY packet was lost — a single drop no longer marks a node down.
    """
    try:
        if _is_windows():
            args = ["ping", "-n", str(PING_COUNT), "-w", str(int(PING_TIMEOUT * 1000)), ip]
        else:
            # -c count, -W per-packet timeout (s), -i interval between packets
            args = ["ping", "-c", str(PING_COUNT), "-W", "2", "-i", "0.3", ip]

        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        stdout, _ = await asyncio.wait_for(
            proc.communicate(), timeout=PING_TIMEOUT + 3
        )
        output = stdout.decode(errors="replace")

        rtts = _parse_all_rtts(output)
        loss = _parse_loss(output)

        if not rtts:
            return None, (loss if loss is not None else 100.0)
        if loss is None:
            loss = round(100.0 * (1 - len(rtts) / PING_COUNT), 1)
        return min(rtts), loss

    except asyncio.TimeoutError:
        logger.debug("ping to %s timed out", ip)
        return None, 100.0
    except Exception as exc:
        logger.debug("ping to %s errored: %s", ip, exc)
        return None, 100.0


def _parse_all_rtts(output: str) -> list[float]:
    """Extract every round-trip time from ping stdout (Linux + Windows)."""
    rtts = [float(m) for m in re.findall(r"time[=<]\s*([0-9]+\.?[0-9]*)\s*ms", output)]
    if not rtts:
        rtts = [float(m) for m in re.findall(r"tempo[=<]\s*([0-9]+\.?[0-9]*)\s*ms", output)]
    return rtts


def _parse_loss(output: str) -> Optional[float]:
    """Extract packet-loss percentage from the ping summary line."""
    m = re.search(r"([0-9]+(?:\.[0-9]+)?)%\s*packet loss", output)
    if m:
        return float(m.group(1))
    m = re.search(r"\(([0-9]+)%\s*loss\)", output)          # Windows
    if m:
        return float(m.group(1))
    return None


async def _tcp_connect(ip: str, port: int = CHECK_PORT) -> bool:
    """TCP connect probe. True if the port accepts within PORT_TIMEOUT."""
    writer = None
    try:
        _, writer = await asyncio.wait_for(
            asyncio.open_connection(ip, port), timeout=PORT_TIMEOUT
        )
        return True
    except (asyncio.TimeoutError, OSError):
        return False
    except Exception:
        return False
    finally:
        if writer is not None:
            try:
                writer.close()
                await writer.wait_closed()
            except Exception:
                pass


# ---------------------------------------------------------------------------
# Aggregated per-node check
# ---------------------------------------------------------------------------
async def _check_single(target: Target, snap: TailscaleSnapshot, ts_fresh: bool) -> NodeStatus:
    """
    Layered probe with hysteresis.

    1. Resolve the node's CURRENT IP from the daemon (falls back to the literal).
    2. Ask the daemon whether the peer is Online — authoritative when available.
    3. Ping (multi-packet) and TCP:22 for latency + a second opinion.
    4. Only report offline after OFFLINE_THRESHOLD consecutive failures.
    """
    name = _norm(target.magicdns)

    live_ip = snap.ip_by_name.get(name)
    ip = live_ip or target.tailscale_ip
    ip_source = "daemon" if live_ip else "static"
    known_peer = name in snap.online_by_name if snap.ok else True

    if live_ip and live_ip != target.tailscale_ip:
        logger.info("%s: IP changed %s -> %s (config is stale)",
                    target.id, target.tailscale_ip, live_ip)

    ts_online = snap.online_by_name.get(name)
    if ts_online is None:
        ts_online = snap.online_by_ip.get(ip, False)

    # Classify how we are actually reaching this peer. A direct LAN endpoint
    # means same network; a relay means Tailscale could not hole-punch, which
    # for a phone almost always means it left WiFi for mobile data.
    cur_addr = snap.curaddr_by_name.get(name) or None
    relay_region = snap.relay_by_name.get(name) or None
    if not ts_online:
        conn_path = "offline"
    elif cur_addr:
        host = cur_addr.rsplit(":", 1)[0].strip("[]")
        private = (
            host.startswith("192.168.")
            or host.startswith("10.")
            or any(host.startswith(f"172.{b}.") for b in range(16, 32))
        )
        conn_path = "direct-lan" if private else "direct-wan"
    else:
        conn_path = "relay"

    (ping_ms, loss), tcp_ok = await asyncio.gather(
        _ping(ip),
        _tcp_connect(ip, CHECK_PORT),
    )

    probe_ok = bool(ts_online) or (ping_ms is not None) or tcp_ok

    if probe_ok:
        _failure_counts[target.id] = 0
    else:
        _failure_counts[target.id] = _failure_counts.get(target.id, 0) + 1

    fails = _failure_counts[target.id]

    if probe_ok:
        status = "online"
    elif fails < OFFLINE_THRESHOLD:
        # Not yet convinced — hold the previous state rather than flapping.
        prev = _node_statuses.get(target.id)
        status = prev.status if prev and prev.status == "online" else "offline"
        if status == "online":
            status = "degraded"
    else:
        status = "offline"

    return NodeStatus(
        id=target.id,
        name=target.name,
        tailscale_ip=ip,
        magicdns=target.magicdns,
        status=status,
        latency_ms=ping_ms,
        port_22=tcp_ok,
        tailscale_online=bool(ts_online),
        consecutive_failures=fails,
        packet_loss_pct=loss,
        ip_source=ip_source,
        ts_stale=not ts_fresh,
        known_peer=known_peer,
        conn_path=conn_path,
        conn_addr=cur_addr,
        relay_region=relay_region,
        last_checked=datetime.now(timezone.utc).isoformat(),
    )


# ---------------------------------------------------------------------------
# Background refresh
# ---------------------------------------------------------------------------
async def refresh_all() -> None:
    """Check every target concurrently, update state, persist to the DB."""
    global _node_statuses, _last_update

    snap, ts_fresh = await _get_tailscale_status()
    if not snap.ok:
        logger.warning("no tailscale data this cycle — falling back to ping/TCP only")

    results = await asyncio.gather(
        *(_check_single(t, snap, ts_fresh) for t in TARGETS),
        return_exceptions=True,
    )

    clean: list[NodeStatus] = []
    async with _state_lock:
        for target, result in zip(TARGETS, results):
            if isinstance(result, NodeStatus):
                _node_statuses[target.id] = result
                clean.append(result)
            else:
                logger.warning("check failed for %s: %s", target.id, result)
                prev = _node_statuses.get(target.id)
                if prev:
                    # Keep the previous reading rather than inventing an outage.
                    prev.last_checked = datetime.now(timezone.utc).isoformat()
                    clean.append(prev)
        _last_update = datetime.now(timezone.utc).isoformat()

    try:
        db = _get_db()
        await db.insert_metrics(clean)
    except Exception:
        logger.exception("failed to persist metrics")


# ---------------------------------------------------------------------------
# Schedulers
# ---------------------------------------------------------------------------
async def scheduler_loop(interval: int = REFRESH_INTERVAL) -> None:
    """Run refresh_all every *interval* seconds forever."""
    logger.info(
        "scheduler started (interval=%ds, ping_count=%d, offline_threshold=%d)",
        interval, PING_COUNT, OFFLINE_THRESHOLD,
    )
    while True:
        start = time.monotonic()
        try:
            await refresh_all()
        except Exception:
            logger.exception("unhandled error in refresh_all")
        await asyncio.sleep(max(0.0, interval - (time.monotonic() - start)))


async def cleanup_loop(interval: int = 3600, retention_days: int = 30) -> None:
    """Prune old rows every *interval* seconds."""
    logger.info("cleanup loop started (interval=%ds, retention=%dd)", interval, retention_days)
    while True:
        try:
            db = _get_db()
            deleted = await db.prune_old_data(retention_days)
            logger.debug("cleanup pruned %d rows", deleted)
        except Exception:
            logger.exception("unhandled error in cleanup_loop")
        await asyncio.sleep(interval)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
async def get_all_statuses() -> dict:
    """Latest snapshot, JSON-serialisable."""
    async with _state_lock:
        return {
            "nodes": [ns.__dict__ for ns in _node_statuses.values()],
            "last_update": _last_update,
            "refresh_interval_seconds": REFRESH_INTERVAL,
            "tailscale_ok": _ts_cache.ok,
            "tailscale_age_seconds": (
                round(time.monotonic() - _ts_cache.fetched_at, 1) if _ts_cache.ok else None
            ),
        }

