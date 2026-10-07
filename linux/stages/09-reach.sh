#!/usr/bin/env bash
# Stage 9: what the VPS reaches on the PC over the tailnet (docs/RESTORE.md
# Stage 9, row 12).
#
#   09-reach.sh
#
# windows/stages/09-acceptance.ps1 runs it as root (sudo -n) over SSH. It
# reads one probe per input line:
#
#   <name> <URL on a tailnet address>
#
# and asks each URL once with curl, from the VPS, with no credentials and
# no redirects. It prints 'FACT reach_<name> <HTTP status>' (000 when
# nothing answered) and a 'STEP' line, never an address or a page.
set -euo pipefail

n=0
while read -r name url extra || [ -n "${name:-}" ]; do
  if [ -z "${name:-}" ]; then continue; fi
  if [[ ! $name =~ ^[a-z0-9_-]{1,40}$ ]] || [[ ! ${url:-} =~ ^http://100\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}:[0-9]{1,5}/[A-Za-z0-9._/-]*$ ]] || [ -n "${extra:-}" ]; then
    echo "FAIL input line $((n + 1)) is not '<name> <tailnet URL>'"
    exit 1
  fi
  n=$((n + 1))
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --proto =http "$url" || true)
  [[ $code =~ ^[0-9]{3}$ ]] || code=000
  echo "FACT reach_$name $code"
  name=''
done
echo "STEP asked $n address(es) on the PC from the VPS"
