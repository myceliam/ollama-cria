#!/bin/sh
# ============================================================
#  mcpo-entrypoint.sh
#  mcpo does NOT expand ${VARS} inside its config file, so we
#  substitute environment variables into a RUNTIME copy before
#  launching mcpo. Real secrets (MCP_ADMIN_TOKEN, CENSYS_PAT,
#  SHODAN_API_KEY, ...) live only in .env / the container env —
#  never in the git-committed config.
# ============================================================
set -eu

SRC="/app/config.json"               # mounted, git-safe (has ${VAR} placeholders)
DST="/app/data/config.runtime.json"  # on the data volume, NOT in git

python3 - "$SRC" "$DST" <<'PY'
import os, re, sys
src, dst = sys.argv[1], sys.argv[2]
cfg = open(src).read()
cfg = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}",
             lambda m: os.environ.get(m.group(1), ""), cfg)
open(dst, "w").write(cfg)
print("[mcpo-entrypoint] runtime config written — env secrets injected")
PY

exec "$@"
