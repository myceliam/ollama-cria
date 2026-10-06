#!/usr/bin/env python3
"""Authenticated Windows PowerShell broker for the Open WebUI native tool.

The broker deliberately is not an MCP server. Open WebUI's native tool owns
the interactive approval popup; the broker accepts only the already-selected
access level and enforces it on the Windows host.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
CONFIG = json.loads((ROOT / "config.json").read_text(encoding="utf-8"))
VALIDATOR = ROOT / "Validate-ReadCommand.ps1"
ELEVATION_LAUNCHER = ROOT / "Invoke-Elevated.ps1"
ELEVATED_RUNNER = ROOT / "Elevated-Runner.ps1"
POWERSHELL = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "PowerShell" / "7" / "pwsh.exe"
CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
TOKEN_NAME = str(CONFIG["token_environment_variable"])
MAX_BODY_BYTES = 64 * 1024
EXECUTION_SLOT = threading.BoundedSemaphore(1)
AUDIT_LOCK = threading.Lock()
SECRET_NAME = re.compile(r"(?i)(token|secret|password|passwd|api[_-]?key|authorization|cookie|credential|pat)")
SECRET_ASSIGNMENT = re.compile(
    r"(?i)\b(token|secret|password|passwd|api[_-]?key|authorization|cookie|credential|pat)\b(\s*[:=]\s*)([^\s,;]+)"
)


def load_token() -> str:
    value = os.environ.get(TOKEN_NAME, "").strip()
    if value:
        return value
    env_path = ROOT.parent / ".env"
    try:
        for line in env_path.read_text(encoding="utf-8-sig").splitlines():
            if line.startswith(f"{TOKEN_NAME}="):
                return line.split("=", 1)[1].strip()
    except OSError:
        return ""
    return ""


TOKEN = load_token()


def fail_start(message: str) -> None:
    print(f"FATAL: {message}", file=sys.stderr, flush=True)
    raise SystemExit(2)


if not TOKEN:
    fail_start(f"{TOKEN_NAME} is not set")
if not POWERSHELL.exists():
    fail_start(f"PowerShell 7 was not found at {POWERSHELL}")
for required in (VALIDATOR, ELEVATION_LAUNCHER, ELEVATED_RUNNER):
    if not required.exists():
        fail_start(f"required file is missing: {required}")


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def sanitised_environment() -> dict[str, str]:
    """Keep normal Windows execution state but do not hand obvious secrets to commands."""
    clean: dict[str, str] = {}
    for name, value in os.environ.items():
        if name == TOKEN_NAME or SECRET_NAME.search(name):
            continue
        clean[name] = value
    clean["POWERSHELL_TELEMETRY_OPTOUT"] = "1"
    return clean


def redact_command(command: str) -> str:
    preview = command.replace("\r", " ").replace("\n", " ")[:800]
    return SECRET_ASSIGNMENT.sub(lambda match: f"{match.group(1)}{match.group(2)}<redacted>", preview)


def rotate_audit(path: Path) -> None:
    if path.exists() and path.stat().st_size >= 5 * 1024 * 1024:
        rotated = path.with_suffix(path.suffix + ".1")
        rotated.unlink(missing_ok=True)
        path.replace(rotated)


def audit(event: dict[str, Any]) -> None:
    path = Path(CONFIG["audit_log"])
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n"
    with AUDIT_LOCK:
        rotate_audit(path)
        with path.open("a", encoding="utf-8", newline="\n") as handle:
            handle.write(line)


def kill_process_tree(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        subprocess.run(
            ["taskkill.exe", "/PID", str(process.pid), "/T", "/F"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
            check=False,
            creationflags=CREATE_NO_WINDOW,
        )
    except Exception:
        try:
            process.kill()
        except Exception:
            pass


def run_process(command: str, cwd: Path, timeout_seconds: int, constrained: bool) -> dict[str, Any]:
    prelude = (
        "$ProgressPreference='SilentlyContinue';"
        "[Console]::InputEncoding=[Text.UTF8Encoding]::new($false);"
        "[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false);"
        "$OutputEncoding=[Text.UTF8Encoding]::new($false);"
    )
    if constrained:
        prelude += "$ExecutionContext.SessionState.LanguageMode='ConstrainedLanguage';"
    encoded = base64.b64encode((prelude + command).encode("utf-16-le")).decode("ascii")
    started = time.monotonic()
    process = subprocess.Popen(
        [str(POWERSHELL), "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
        cwd=str(cwd),
        env=sanitised_environment(),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        creationflags=CREATE_NO_WINDOW,
    )
    limit = int(CONFIG["max_output_chars"]) * 4
    buckets: dict[str, list[bytes]] = {"stdout": [], "stderr": []}
    count = 0
    lock = threading.Lock()
    overflow = threading.Event()

    def drain(name: str, stream: Any) -> None:
        nonlocal count
        while True:
            chunk = stream.read(4096)
            if not chunk:
                return
            with lock:
                room = max(0, limit - count)
                if room:
                    kept = chunk[:room]
                    buckets[name].append(kept)
                    count += len(kept)
                if len(chunk) > room or count >= limit:
                    overflow.set()
                    return

    threads = [
        threading.Thread(target=drain, args=("stdout", process.stdout), daemon=True),
        threading.Thread(target=drain, args=("stderr", process.stderr), daemon=True),
    ]
    for thread in threads:
        thread.start()

    deadline = started + timeout_seconds
    timed_out = False
    while process.poll() is None:
        if overflow.is_set():
            kill_process_tree(process)
            break
        if time.monotonic() >= deadline:
            timed_out = True
            kill_process_tree(process)
            break
        time.sleep(0.05)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        kill_process_tree(process)
    for thread in threads:
        thread.join(timeout=2)

    stdout = b"".join(buckets["stdout"]).decode("utf-8", errors="replace")
    stderr = b"".join(buckets["stderr"]).decode("utf-8", errors="replace")
    max_chars = int(CONFIG["max_output_chars"])
    output_truncated = overflow.is_set() or len(stdout) + len(stderr) > max_chars
    if len(stdout) + len(stderr) > max_chars:
        stdout = stdout[:max_chars]
        stderr = stderr[: max(0, max_chars - len(stdout))]
    status = "timed_out" if timed_out else ("output_limit" if overflow.is_set() else ("ok" if process.returncode == 0 else "command_failed"))
    return {
        "status": status,
        "exit_code": process.returncode,
        "stdout": stdout,
        "stderr": stderr,
        "timed_out": timed_out,
        "output_truncated": output_truncated,
        "duration_ms": round((time.monotonic() - started) * 1000),
    }


def validate_read(command: str) -> tuple[bool, list[str]]:
    process = subprocess.run(
        [str(POWERSHELL), "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(VALIDATOR)],
        input=command.encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=20,
        check=False,
        creationflags=CREATE_NO_WINDOW,
        env=sanitised_environment(),
    )
    try:
        result = json.loads(process.stdout.decode("utf-8", errors="replace"))
    except json.JSONDecodeError:
        return False, ["The read-only validator failed to return valid JSON."]
    return bool(result.get("allowed")), [str(item) for item in result.get("reasons", [])]


def run_elevated(command: str, cwd: Path, timeout_seconds: int) -> dict[str, Any]:
    command_b64 = base64.b64encode(command.encode("utf-8")).decode("ascii")
    cwd_b64 = base64.b64encode(str(cwd).encode("utf-8")).decode("ascii")
    result_path = ROOT / "state" / "results" / f"{secrets.token_hex(16)}.json"
    result_path.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    launcher = subprocess.Popen(
        [
            str(POWERSHELL), "-NoLogo", "-NoProfile", "-NonInteractive", "-File", str(ELEVATION_LAUNCHER),
            "-RunnerPath", str(ELEVATED_RUNNER),
            "-CommandBase64", command_b64,
            "-WorkingDirectoryBase64", cwd_b64,
            "-TimeoutSeconds", str(timeout_seconds),
            "-MaxOutputChars", str(CONFIG["max_output_chars"]),
            "-ResultPath", str(result_path),
        ],
        cwd=str(ROOT),
        env=sanitised_environment(),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=CREATE_NO_WINDOW,
    )
    try:
        launcher.wait(timeout=timeout_seconds + 60)
    except subprocess.TimeoutExpired:
        kill_process_tree(launcher)
        return {
            "status": "elevation_timeout",
            "exit_code": None,
            "stdout": "",
            "stderr": "The UAC/elevated command did not finish within the allowed time.",
            "timed_out": True,
            "output_truncated": False,
            "duration_ms": round((time.monotonic() - started) * 1000),
        }
    try:
        result = json.loads(result_path.read_text(encoding="utf-8-sig"))
        result["duration_ms"] = round((time.monotonic() - started) * 1000)
        return result
    except (OSError, json.JSONDecodeError) as exc:
        return {
            "status": "elevation_failed",
            "exit_code": launcher.returncode,
            "stdout": "",
            "stderr": f"The elevated runner returned no valid result: {type(exc).__name__}",
            "timed_out": False,
            "output_truncated": False,
            "duration_ms": round((time.monotonic() - started) * 1000),
        }
    finally:
        result_path.unlink(missing_ok=True)


def resolve_working_directory(value: Any) -> Path:
    raw = str(value or CONFIG["default_working_directory"]).strip()
    path = Path(raw).expanduser().resolve(strict=True)
    if not path.is_dir():
        raise ValueError("working_directory must name an existing directory")
    return path


def execute(payload: dict[str, Any]) -> tuple[int, dict[str, Any]]:
    request_id = secrets.token_hex(8)
    command = str(payload.get("command") or "")
    mode = str(payload.get("mode") or "")
    reason = str(payload.get("reason") or "").strip()
    requested_access = str(payload.get("requested_access") or "").strip()
    caller = str(payload.get("caller") or "unknown")[:200]
    if not command.strip():
        return HTTPStatus.BAD_REQUEST, {"status": "invalid_request", "message": "command is required", "request_id": request_id}
    if len(command) > int(CONFIG["max_command_chars"]):
        return HTTPStatus.BAD_REQUEST, {"status": "invalid_request", "message": "command exceeds the configured length limit", "request_id": request_id}
    if mode not in {"read", "read_write", "read_write_elevated"}:
        return HTTPStatus.BAD_REQUEST, {"status": "invalid_request", "message": "mode must be read, read_write, or read_write_elevated", "request_id": request_id}
    if mode == "read_write_elevated" and requested_access != "read_write_elevated":
        result = {
            "status": "elevation_not_requested",
            "message": "Elevated mode requires requested_access=read_write_elevated. No command ran.",
            "request_id": request_id,
            "selected_access": mode,
            "requested_access": requested_access,
        }
        audit({
            "timestamp": utc_now(), "request_id": request_id, "caller": caller, "mode": mode,
            "requested_access": requested_access, "reason": reason[:1000],
            "command_sha256": hashlib.sha256(command.encode()).hexdigest(), "command_preview": redact_command(command),
            "status": result["status"],
        })
        return HTTPStatus.OK, result
    if mode == "read_write_elevated" and len(command) > int(CONFIG["max_elevated_command_chars"]):
        return HTTPStatus.BAD_REQUEST, {"status": "invalid_request", "message": "elevated command exceeds the configured length limit", "request_id": request_id}
    try:
        timeout_seconds = int(payload.get("timeout_seconds") or CONFIG["default_timeout_seconds"])
    except (TypeError, ValueError):
        return HTTPStatus.BAD_REQUEST, {"status": "invalid_request", "message": "timeout_seconds must be an integer", "request_id": request_id}
    timeout_seconds = max(1, min(timeout_seconds, int(CONFIG["max_timeout_seconds"])))
    try:
        cwd = resolve_working_directory(payload.get("working_directory"))
    except (OSError, ValueError) as exc:
        return HTTPStatus.BAD_REQUEST, {"status": "invalid_request", "message": str(exc), "request_id": request_id}

    if mode == "read":
        allowed, reasons = validate_read(command)
        if not allowed:
            result: dict[str, Any] = {
                "status": "read_policy_denied",
                "message": "The selected Read mode rejected this command. Choose Read/Write only if you intend to permit mutation or native executable use.",
                "policy_reasons": reasons,
                "request_id": request_id,
                "selected_access": mode,
                "requested_access": requested_access,
            }
            audit({
                "timestamp": utc_now(), "request_id": request_id, "caller": caller, "mode": mode,
                "requested_access": requested_access, "reason": reason[:1000], "cwd": str(cwd),
                "command_sha256": hashlib.sha256(command.encode()).hexdigest(), "command_preview": redact_command(command),
                "status": result["status"], "policy_reasons": reasons,
            })
            return HTTPStatus.OK, result
        result = run_process(command, cwd, timeout_seconds, constrained=True)
    elif mode == "read_write":
        result = run_process(command, cwd, timeout_seconds, constrained=False)
    else:
        result = run_elevated(command, cwd, timeout_seconds)

    result.update({
        "request_id": request_id,
        "selected_access": mode,
        "requested_access": requested_access,
        "working_directory": str(cwd),
    })
    audit({
        "timestamp": utc_now(), "request_id": request_id, "caller": caller, "mode": mode,
        "requested_access": requested_access, "reason": reason[:1000], "cwd": str(cwd),
        "command_sha256": hashlib.sha256(command.encode()).hexdigest(), "command_preview": redact_command(command),
        "status": result.get("status"), "exit_code": result.get("exit_code"),
        "timed_out": result.get("timed_out"), "output_truncated": result.get("output_truncated"),
        "duration_ms": result.get("duration_ms"),
    })
    return HTTPStatus.OK, result


class Handler(BaseHTTPRequestHandler):
    server_version = "WindowsPowerShellOWUITool/1.0"

    def log_message(self, _format: str, *_args: Any) -> None:
        return

    def send_json(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(int(status))
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def authorised(self) -> bool:
        supplied = self.headers.get("Authorization", "")
        if not supplied.startswith("Bearer "):
            return False
        return hmac.compare_digest(supplied[7:].strip(), TOKEN)

    def do_GET(self) -> None:  # noqa: N802
        if self.path.rstrip("/") == "/health":
            self.send_json(HTTPStatus.OK, {
                "status": "ok", "service": "windows-powershell-tool", "version": "1.0.0",
                "bind": f"{CONFIG['bind_host']}:{CONFIG['port']}", "process_elevated": False,
            })
            return
        self.send_json(HTTPStatus.NOT_FOUND, {"status": "not_found"})

    def do_POST(self) -> None:  # noqa: N802
        if self.path.rstrip("/") != "/execute":
            self.send_json(HTTPStatus.NOT_FOUND, {"status": "not_found"})
            return
        if not self.authorised():
            self.send_json(HTTPStatus.UNAUTHORIZED, {"status": "unauthorised"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY_BYTES:
            self.send_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"status": "invalid_request", "message": "invalid request size"})
            return
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self.send_json(HTTPStatus.BAD_REQUEST, {"status": "invalid_request", "message": "body must be valid UTF-8 JSON"})
            return
        if not isinstance(payload, dict):
            self.send_json(HTTPStatus.BAD_REQUEST, {"status": "invalid_request", "message": "body must be a JSON object"})
            return
        if not EXECUTION_SLOT.acquire(blocking=False):
            self.send_json(HTTPStatus.TOO_MANY_REQUESTS, {"status": "busy", "message": "another PowerShell command is already running"})
            return
        try:
            status, result = execute(payload)
            self.send_json(status, result)
        except Exception as exc:
            request_id = secrets.token_hex(8)
            audit({"timestamp": utc_now(), "request_id": request_id, "status": "broker_error", "error_type": type(exc).__name__})
            self.send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {
                "status": "broker_error", "message": f"The broker failed safely: {type(exc).__name__}", "request_id": request_id,
            })
        finally:
            EXECUTION_SLOT.release()


def main() -> None:
    bind_host = str(CONFIG["bind_host"])
    port = int(CONFIG["port"])
    deadline = time.monotonic() + 120
    while True:
        try:
            server = ThreadingHTTPServer((bind_host, port), Handler)
            break
        except OSError as exc:
            if getattr(exc, "winerror", None) != 10049 or time.monotonic() >= deadline:
                raise
            time.sleep(2)
    print(f"Windows PowerShell OWUI tool listening on http://{bind_host}:{port}", flush=True)
    server.serve_forever(poll_interval=0.5)


if __name__ == "__main__":
    main()
