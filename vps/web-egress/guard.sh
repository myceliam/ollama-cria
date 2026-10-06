#!/bin/bash
set -euo pipefail
cd /home/liam/owui-web-egress
# Load firewall before selecting the VPN or starting any container.
if nft list table inet owui_web >/dev/null 2>&1; then
    { echo 'delete table inet owui_web'; cat guard.nft; } | nft -f -
else
    nft -f guard.nft
fi
ensure_rule() {
    local family="$1" priority="$2"; shift 2
    # Our priorities are reserved in this installation. Do not touch Tailscale's.
    if ! ip "$family" rule show | grep -q "^${priority}:"; then
        ip "$family" rule add priority "$priority" "$@"
    fi
}
# Tailscale's fwmark rules at 5210-5250 remain ahead of these rules.
# Keep host/public-service traffic on main while this subnet uses table 52.
ensure_rule -4 5260 to 100.64.0.0/10 lookup 52
ensure_rule -4 5261 to 172.30.88.0/24 lookup main
# 2026-09-19: rules 5262/5263 REMOVED. They sent this subnet through the
# Tailscale exit node and prohibited it if that failed. gluetun is now the
# only tunnel: it holds the Mullvad multihop WireGuard session (entry
# se-sto-202, exit ch-zrh-003) and its own firewall is the kill switch,
# proven by stopping the tunnel and confirming egress was BLOCKED rather
# than falling back to the IONOS address.
# Leaving 5262 out while keeping 5263 would prohibit gluetun's own
# handshake and break everything - they go together or not at all.
ensure_rule -4 5264 lookup main
ensure_rule -6 5260 to fd7a:115c:a1e0::/48 lookup 52
ensure_rule -6 5264 lookup main
# This VPS had no ordinary IPv6 internet route; do not fall through to the VPN.
ensure_rule -6 5265 prohibit
# 2026-09-19: host exit node REMOVED, on Liam's call. It was a single
# non-rotating node and therefore a single point of failure; nothing
# consumes it now that gluetun carries the container traffic. Clearing it
# makes SSH-over-tailnet provably independent of Mullvad rather than
# incidentally independent.
# NOTE it was already inert for the HOST: rule 5264 (from all lookup main)
# sits ahead of Tailscale's own 5270 (from all lookup 52), so host traffic
# never reached it. Measured host egress was always 185.230.216.117.
tailscale set --exit-node= --exit-node-allow-lan-access=true
