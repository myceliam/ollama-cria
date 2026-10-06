#!/usr/bin/env python3
"""
check-mcpo-tools.py — how many functions is each mcpo server ACTUALLY serving?

A server can return HTTP 200 with "paths": {} — a live endpoint offering zero
tools. OWUI registers it, enables it, shows it in Admin Settings, and the model
can never call anything on it. This is the failure mode that looks like
"my tools disappeared".

Run it INSIDE the mcpo container (it talks to 127.0.0.1:8000):

    docker cp E:\\ai\\ollama\\check-mcpo-tools.py mcpo-core:/tmp/chk.py
    docker exec mcpo-core python3 /tmp/chk.py

Exit code 1 if any enabled server is serving zero functions.
"""
import json
import sys
import urllib.request

# Read the live runtime config so the list never drifts from what mcpo mounted.
CONFIG = "/app/data/config.runtime.json"
BASE = "http://127.0.0.1:8000"


def main() -> int:
    try:
        with open(CONFIG) as fh:
            names = list(json.load(fh)["mcpServers"].keys())
    except Exception as exc:
        print(f"Could not read {CONFIG}: {exc}")
        return 2

    rows = []
    for name in names:
        try:
            with urllib.request.urlopen(f"{BASE}/{name}/openapi.json", timeout=25) as resp:
                spec = json.load(resp)
            count = len(spec.get("paths", {}))
        except Exception as exc:
            count = -1
            print(f"  !! {name}: {type(exc).__name__}: {exc}", file=sys.stderr)
        rows.append((count, name))

    total = sum(c for c, _ in rows if c > 0)
    dead = [n for c, n in rows if c <= 0]

    print(f"mcpo functions by server  (total: {total})\n")
    for count, name in sorted(rows, reverse=True):
        flag = "  <-- DEAD" if count <= 0 else ""
        print(f"  {count:>3}  {name}{flag}")

    if dead:
        print(f"\nZERO-FUNCTION SERVERS ({len(dead)}): {', '.join(dead)}")
        print("These are registered and enabled in OWUI but serve nothing.")
        print("Check: docker logs mcpo-core | grep -i 'Failed to establish'")
        print("NOTE: one server failing during startup can cancel every server")
        print("      initialised AFTER it in config order — fix the FIRST failure.")
        return 1

    print("\nAll servers are serving functions.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
