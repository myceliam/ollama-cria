#!/usr/bin/env python3
"""
mcp_risk_scanner.py — read-only MCP risk scanner for MCPO/OpenWebUI configs.

Intent:
- Audit MCP/MCPO config exposure without needing Docker socket access.
- Do not execute tools, do not call networks, do not reveal secret values by default.
- Designed for stdio MCP usage inside the baked mcpo-core image.
"""
from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("mcp_risk_scanner")

DEFAULT_CONFIG_PATH = os.environ.get("MCP_RISK_CONFIG_PATH", "/app/data/config.runtime.json")
STATIC_CONFIG_PATH = os.environ.get("MCP_RISK_STATIC_CONFIG_PATH", "/app/config.json")
SECRET_KEY_RE = re.compile(r"(TOKEN|KEY|SECRET|PAT|PASSWORD|PASS|AUTH|BEARER|COOKIE)", re.I)
PLACEHOLDER_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


def _read_json(path: str) -> Dict[str, Any]:
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"Config path does not exist: {path}")
    with p.open("r", encoding="utf-8") as f:
        return json.load(f)


def _redact_value(key: str, value: Any, include_values: bool = False) -> Any:
    if include_values:
        return value
    if SECRET_KEY_RE.search(key):
        if value in (None, ""):
            return ""
        return "<redacted>"
    if isinstance(value, str):
        if value.startswith("Bearer "):
            return "Bearer <redacted>"
        if len(value) > 24 and re.search(r"[A-Za-z0-9_\-]{20,}", value):
            return "<possibly-secret-redacted>"
    return value


def _redact_mapping(mapping: Dict[str, Any], include_values: bool = False) -> Dict[str, Any]:
    return {k: _redact_value(k, v, include_values) for k, v in mapping.items()}


def _server_blob(server: Dict[str, Any]) -> str:
    return json.dumps(server, sort_keys=True).lower()


def _has_runtime_package_manager(server: Dict[str, Any]) -> bool:
    cmd = str(server.get("command", "")).lower()
    args = [str(a).lower() for a in server.get("args", [])]
    return cmd in {"npx", "uvx", "uv", "pipx", "pip"} or any(a in {"npx", "uvx", "pipx"} for a in args)


def _arg_is_pinned(arg: str) -> bool:
    # npm scoped packages: @scope/name@1.2.3; uv/python: pkg==1.2.3; git commit-ish refs.
    if "==" in arg:
        return True
    if re.search(r"@[0-9]{4}\.[0-9]+\.[0-9]+", arg):
        return True
    if re.search(r"@[0-9]+\.[0-9]+\.[0-9]+", arg):
        return True
    if re.search(r"@[a-f0-9]{12,40}$", arg, re.I):
        return True
    return False


def _package_pin_findings(server: Dict[str, Any]) -> Tuple[int, List[str]]:
    score = 0
    findings: List[str] = []
    args = [str(a) for a in server.get("args", [])]
    if str(server.get("command", "")).lower() == "npx" and "-y" in args:
        pkg_args = [a for a in args if a not in {"-y"}]
        package_like = [a for a in pkg_args if not a.startswith("/") and not a.startswith("-")]
        if package_like and not any(_arg_is_pinned(a) for a in package_like):
            score += 2
            findings.append("Uses npx -y with an apparently unpinned package.")
        else:
            findings.append("Uses npx -y but package appears pinned/baked; still verify image cache.")
            score += 1
    if str(server.get("command", "")).lower() in {"uvx", "uv"}:
        joined = " ".join(args)
        if "uvx" in str(server.get("command", "")).lower() and "==" not in joined and "git+" not in joined and "@" not in joined:
            score += 2
            findings.append("Uses uvx without an obvious version/commit pin.")
    if "latest" in _server_blob(server):
        score += 2
        findings.append("References a moving 'latest' tag/string.")
    return score, findings


def _classify_server(name: str, server: Dict[str, Any]) -> Dict[str, Any]:
    lname = name.lower()
    blob = _server_blob(server)
    score = 1
    findings: List[str] = []
    mitigations: List[str] = []

    if server.get("type") in {"streamable_http", "sse", "http"} or "url" in server:
        score += 2
        url = str(server.get("url", ""))
        findings.append(f"Remote/HTTP MCP endpoint configured: {url or '<unknown url>'}.")
        if url.startswith("http://"):
            score += 2
            findings.append("Plain HTTP endpoint. Acceptable only on trusted internal Docker/Tailscale paths.")
            mitigations.append("Keep bound to localhost/private Docker networks, or terminate TLS if exposed beyond trusted network.")
        if "headers" in server:
            score += 2
            findings.append("Uses authentication headers/secrets.")
            mitigations.append("Keep tokens in runtime env only; rotate if logs or configs leak.")

    if _has_runtime_package_manager(server):
        s, f = _package_pin_findings(server)
        score += s
        findings.extend(f)

    if "filesystem" in lname or "/workspace" in blob:
        score += 5
        findings.append("Filesystem/workspace access present; may read/write user files depending on exposed tools.")
        mitigations.append("Expose only to trusted coding models; keep workspace scope narrow.")

    if "memory" in lname or "memory_file_path" in blob:
        score += 2
        findings.append("Persistent memory/state access present.")
        mitigations.append("Do not store secrets or sensitive personal data in MCP memory.")

    if any(x in lname or x in blob for x in ["browser", "playwright", "patchright", "stealth"]):
        score += 6
        findings.append("Browser automation/control capability detected.")
        mitigations.append("Require confirmation before account-impacting actions; isolate browser sessions.")

    if any(x in lname for x in ["shodan", "censys", "osint", "virustotal", "securitytrails", "mitre", "cve", "nvd"]):
        score += 4
        findings.append("Cyber/OSINT/security intelligence capability detected.")
        mitigations.append("Constrain to lawful/owned/authorised targets and avoid auto-approving destructive workflows.")

    if any(x in lname or x in blob for x in ["fetch", "firecrawl", "jina", "searx", "web_search", "web"]):
        score += 3
        findings.append("External web/search/fetch capability detected.")
        mitigations.append("Maintain SSRF/private-network protections where available, e.g. ALLOW_PRIVATE_FETCH=false.")

    if "semgrep" in lname or "semgrep" in blob:
        score += 2
        findings.append("Code security scanning capability detected; generally low risk but reads code snippets/files supplied to it.")
        mitigations.append("Good candidate for code-focused models; keep cloud token optional unless needed.")

    if "risk" in lname and "scanner" in lname:
        score += 1
        findings.append("Read-only config audit tool detected.")
        mitigations.append("Keep it read-only; do not add Docker socket or shell execution to this tool.")

    if any(x in lname or x in blob for x in ["docker.sock", "dozzle", "container", "net_admin", "net_raw"]):
        score += 6
        findings.append("Docker/container-level or elevated network capability indicator detected.")
        mitigations.append("Avoid giving write-capable Docker/socket access to models.")

    if "headers" in server:
        headers = server.get("headers") or {}
        for hk, hv in headers.items():
            if SECRET_KEY_RE.search(hk) or SECRET_KEY_RE.search(str(hv)):
                findings.append(f"Secret-bearing header detected: {hk}.")

    env = server.get("env") or {}
    if isinstance(env, dict):
        secret_envs = [k for k in env if SECRET_KEY_RE.search(k)]
        if secret_envs:
            score += min(3, len(secret_envs))
            findings.append("Secret-bearing env vars referenced: " + ", ".join(sorted(secret_envs)) + ".")
            mitigations.append("Confirm env vars are injected at runtime and not committed with real values.")
        private_fetch = str(env.get("ALLOW_PRIVATE_FETCH", "")).lower()
        if private_fetch == "true":
            score += 4
            findings.append("ALLOW_PRIVATE_FETCH=true increases SSRF/private-network risk.")
        elif private_fetch == "false":
            findings.append("ALLOW_PRIVATE_FETCH=false is a good SSRF hardening choice.")

    score = max(1, min(10, score))
    if score >= 8:
        level = "HIGH"
    elif score >= 5:
        level = "MEDIUM"
    else:
        level = "LOW"
    return {
        "server": name,
        "risk_score": score,
        "risk_level": level,
        "findings": findings or ["No major risk indicators detected from config alone."],
        "mitigations": sorted(set(mitigations)),
        "summary": f"{name}: {level} risk ({score}/10)",
    }


def _audit_config_obj(config: Dict[str, Any], include_env_values: bool = False) -> Dict[str, Any]:
    servers = config.get("mcpServers", {})
    if not isinstance(servers, dict):
        raise ValueError("Config must contain an object at mcpServers")

    results = [_classify_server(name, server if isinstance(server, dict) else {}) for name, server in servers.items()]
    counts = {"LOW": 0, "MEDIUM": 0, "HIGH": 0}
    for r in results:
        counts[r["risk_level"]] += 1

    high = [r for r in results if r["risk_level"] == "HIGH"]
    medium = [r for r in results if r["risk_level"] == "MEDIUM"]

    global_findings: List[str] = []
    if len(results) > 20:
        global_findings.append("Large visible tool surface. Prefer enabling MCPs per model/submodel rather than globally.")
    if high:
        global_findings.append("High-risk tools are present; avoid exposing them to weak models or broad auto-approve policies.")
    if any("Plain HTTP" in " ".join(r["findings"]) for r in results):
        global_findings.append("Plain HTTP endpoints exist; acceptable only for internal Docker/Tailscale/localhost paths.")

    safe_servers = {}
    for name, server in servers.items():
        if isinstance(server, dict):
            safe = dict(server)
            if isinstance(safe.get("env"), dict):
                safe["env"] = _redact_mapping(safe["env"], include_env_values)
            if isinstance(safe.get("headers"), dict):
                safe["headers"] = _redact_mapping(safe["headers"], include_env_values)
            safe_servers[name] = safe

    return {
        "server_count": len(results),
        "risk_counts": counts,
        "global_findings": global_findings,
        "results": results,
        "redacted_config_view": {"mcpServers": safe_servers},
    }


def _to_markdown(report: Dict[str, Any]) -> str:
    lines: List[str] = []
    lines.append("# MCP Risk Scanner Report")
    lines.append("")
    lines.append(f"Servers audited: **{report['server_count']}**")
    lines.append(f"Risk counts: **HIGH {report['risk_counts']['HIGH']}**, **MEDIUM {report['risk_counts']['MEDIUM']}**, **LOW {report['risk_counts']['LOW']}**")
    lines.append("")
    if report.get("global_findings"):
        lines.append("## Global Findings")
        for item in report["global_findings"]:
            lines.append(f"- {item}")
        lines.append("")
    lines.append("## Server Scores")
    lines.append("| Server | Score | Level | Key finding |")
    lines.append("|---|---:|---|---|")
    for r in sorted(report["results"], key=lambda x: (-x["risk_score"], x["server"])):
        finding = (r["findings"][0] if r["findings"] else "No major finding").replace("|", "\\|")
        lines.append(f"| `{r['server']}` | {r['risk_score']}/10 | {r['risk_level']} | {finding} |")
    lines.append("")
    lines.append("## Detailed Findings")
    for r in sorted(report["results"], key=lambda x: (-x["risk_score"], x["server"])):
        lines.append(f"### `{r['server']}` — {r['risk_level']} ({r['risk_score']}/10)")
        for f in r["findings"]:
            lines.append(f"- {f}")
        if r["mitigations"]:
            lines.append("Mitigations:")
            for m in r["mitigations"]:
                lines.append(f"- {m}")
        lines.append("")
    return "\n".join(lines)


@mcp.tool()
def audit_mcp_config(path: Optional[str] = None, include_env_values: bool = False, output: str = "markdown") -> str:
    """Audit an MCP/MCPO config JSON file and return risk scores. Read-only."""
    target = path or DEFAULT_CONFIG_PATH
    report = _audit_config_obj(_read_json(target), include_env_values=include_env_values)
    if output.lower() == "json":
        return json.dumps(report, indent=2, ensure_ascii=False)
    return _to_markdown(report)


@mcp.tool()
def audit_static_config(include_env_values: bool = False, output: str = "markdown") -> str:
    """Audit the mounted source config, usually /app/config.json, before env substitution. Read-only."""
    report = _audit_config_obj(_read_json(STATIC_CONFIG_PATH), include_env_values=include_env_values)
    if output.lower() == "json":
        return json.dumps(report, indent=2, ensure_ascii=False)
    return _to_markdown(report)


@mcp.tool()
def audit_mcp_config_text(config_json: str, include_env_values: bool = False, output: str = "markdown") -> str:
    """Audit MCP config JSON supplied as text. Read-only; useful for pasted configs."""
    report = _audit_config_obj(json.loads(config_json), include_env_values=include_env_values)
    if output.lower() == "json":
        return json.dumps(report, indent=2, ensure_ascii=False)
    return _to_markdown(report)


@mcp.tool()
def explain_risk_model() -> str:
    """Explain how the MCP risk scanner scores servers."""
    return """# MCP Risk Scanner Scoring Model

This is a defensive/read-only heuristic scanner. It does not execute MCP servers or test exploitability.

Signals that raise score:
- filesystem/workspace access
- browser automation
- Docker/container/elevated network indicators
- cyber/OSINT tools and API tokens
- external web/fetch/search tools
- plaintext HTTP endpoints
- secret-bearing env vars or headers
- runtime package managers such as npx/uvx, especially unpinned packages
- moving `latest` tags/strings

Scores:
- 1–4 LOW: narrow or mostly read-only utility
- 5–7 MEDIUM: network, tokens, persistence, or code access
- 8–10 HIGH: browser control, filesystem write potential, Docker/container level capability, or powerful security tooling

Recommended usage:
- Enable high-risk tools only for trusted/high-capability models.
- Keep tools per-model/submodel rather than globally enabled.
- Keep this scanner read-only; do not add Docker socket or shell execution to it.
"""


if __name__ == "__main__":
    mcp.run()
