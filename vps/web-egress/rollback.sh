#!/bin/bash
# Stop only the migrated workload; keep its files, images and cached data.
set -euo pipefail
cd /home/liam/owui-web-egress
sudo -n docker compose -f compose.yml stop
# The captured pre-migration VPS prefs had no exit node selected.
sudo -n tailscale set --exit-node=
sudo -n systemctl disable --now owui-web-egress-guard.service
sudo -n rm -f /etc/systemd/system/docker.service.d/owui-web-egress.conf
sudo -n systemctl daemon-reload
for priority in 5260 5261 5262 5263 5264; do
    sudo -n ip -4 rule del priority "$priority" 2>/dev/null || true
done
for priority in 5260 5264 5265; do
    sudo -n ip -6 rule del priority "$priority" 2>/dev/null || true
done
sudo -n nft delete table inet owui_web
echo 'VPS workload stopped and pre-migration routing restored. Data retained.'
