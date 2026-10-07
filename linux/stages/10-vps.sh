#!/usr/bin/env bash
# Stage 10: the VPS's part of the rehearsal (docs/RESTORE.md Stage 10).
#
#   10-vps.sh boot
#   10-vps.sh reboot
#   10-vps.sh guard-break <account>
#   10-vps.sh kill-switch        (10-killswitch.py on standard input)
#   10-vps.sh public-ip
#   10-vps.sh probe              ('<public address> <port>' per input line)
#
# windows/stages/10-rehearsal.ps1 runs it as root (sudo -n) over SSH. It
# runs reboot, guard-break and kill-switch only on the rebuilt VPS (the
# host key Stage 2 checked) and only once Liam has accepted 'vps-tests'.
#
#   boot         FACT boot_id; guard_first yes|no|unknown (the guard was
#                active before dockerd started); guard_active; docker_active.
#   reboot       restarts the VPS 5 seconds after this command returns.
#   guard-break  breaks the guard on purpose with a drop-in under /run
#                (ExecStart=/bin/false; /run is empty again after a boot),
#                stops Docker and the guard, asks systemd to start Docker and
#                reports whether it refused (C-20, C-43). Then it removes the
#                drop-in, starts the guard and Docker, and waits up to five
#                minutes for both compose projects. A trap restores on any
#                exit.
#   kill-switch  runs the Python test inside the Brave/Jina gateway's
#                container, which shares gluetun's network namespace: it
#                stops the tunnel through gluetun's control server, checks
#                that everything fails closed and starts the tunnel again
#                (C-21). A trap starts the tunnel again on any exit.
#   public-ip    the VPS's own public IPv4 and IPv6, from the host (not the
#                tunnel), and the TCP ports anything listens on. The only
#                place a VPS script prints an address: the controller keeps
#                it in memory and never writes it down.
#   probe        whether each public address and port accepts a TCP
#                connection from here: FACT probe_<4|6>_<port> open|closed.
#                It never prints the address.
#
# It prints 'STEP', 'FACT <name> <value>' and 'FAIL <text>' lines like the
# other stage scripts. Long output goes to $log.
#
# CRIA_ROOT (tests only) puts every file it reads or writes under another
# folder, and skips the waits.
set -euo pipefail

mode=${1:-}
user=${2:-}
root=${CRIA_ROOT:-}
guard=owui-web-egress-guard.service
gateway=vps-web-brave-jina-gateway
log=$root/var/log/ollama-cria/stage-10.log

step() { printf 'STEP %s\n' "$*"; }
fact() { printf 'FACT %s %s\n' "$1" "$2"; }
fail() { printf 'FAIL %s\n' "$*"; exit 1; }
pause() { [ -n "$root" ] || sleep "$1"; }

case "$mode" in
  boot | reboot | kill-switch | public-ip | probe) ;;
  guard-break) [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || fail 'usage: 10-vps.sh guard-break <account>' ;;
  *) fail 'usage: 10-vps.sh boot|reboot|guard-break <account>|kill-switch|public-ip|probe' ;;
esac
[ "$(id -u)" = 0 ] || fail 'run as root (sudo -n)'
install -d -m 0755 "$(dirname -- "$log")"

active() { if systemctl is-active --quiet "$1" 2>/dev/null; then echo yes; else echo no; fi; }
guard_loaded() { nft list table inet owui_web >/dev/null 2>&1 && [ "$(ip -4 rule show | grep -c '^5260:' || true)" -ge 1 ]; }
docker_needs_guard() {
  local s
  s=$(systemctl show docker -p Requires -p After 2>/dev/null || true)
  [ "$(grep -c "$guard" <<<"$s" || true)" -ge 2 ]
}
compose() { docker compose --project-directory "$root$1" "${@:2}"; }
compose_state() {
  local all up
  all=$(compose "$1" ps -a --format '{{.Service}}' 2>/dev/null | grep -c . || true)
  up=$(compose "$1" ps --status running --format '{{.Service}}' 2>/dev/null | grep -c . || true)
  echo "$up/$all"
}
all_up() { [[ $1 =~ ^([1-9][0-9]*)/([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]; }
health() { docker inspect --format '{{.State.Health.Status}}' vps-web-gluetun 2>/dev/null || echo missing; }

# A public IPv4 address (not private, loopback, link-local, the tailnet's
# range or multicast), or a global unicast IPv6 one (2000::/3).
public() {
  local a=$1 o
  if [[ $a =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    for o in "${BASH_REMATCH[@]:1}"; do ((10#$o <= 255)) || return 1; done
    local a1=$((10#${BASH_REMATCH[1]})) a2=$((10#${BASH_REMATCH[2]}))
    if ((a1 == 0 || a1 == 10 || a1 == 127 || a1 >= 224)); then return 1; fi
    if ((a1 == 100 && a2 >= 64 && a2 <= 127)); then return 1; fi
    if ((a1 == 169 && a2 == 254)) || ((a1 == 172 && a2 >= 16 && a2 <= 31)) || ((a1 == 192 && a2 == 168)); then return 1; fi
    return 0
  fi
  [[ $a =~ ^[23][0-9a-fA-F]{3}:[0-9a-fA-F:]*$ ]]
}

case "$mode" in
  boot)
    fact boot_id "$(tr -cd '0-9a-f-' <"$root/proc/sys/kernel/random/boot_id")"
    g=$(systemctl show "$guard" -p ActiveEnterTimestampMonotonic --value 2>/dev/null || true)
    d=$(systemctl show docker.service -p ExecMainStartTimestampMonotonic --value 2>/dev/null || true)
    if [[ $g =~ ^[1-9][0-9]*$ && $d =~ ^[1-9][0-9]*$ ]]; then
      if ((g <= d)); then fact guard_first yes; else fact guard_first no; fi
    else
      fact guard_first unknown
    fi
    fact guard_active "$(active "$guard")"
    fact docker_active "$(active docker.service)"
    ;;

  reboot)
    systemd-run --on-active=5 --unit="ollama-cria-reboot-$$" /bin/systemctl reboot >>"$log" 2>&1 || fail 'systemd-run could not schedule the restart'
    step 'the VPS restarts in 5 seconds'
    ;;

  guard-break)
    egress=/home/$user/owui-web-egress
    kokoro=/home/$user/kokoro
    dropdir=$root/run/systemd/system/$guard.d
    drop=$dropdir/zz-ollama-cria-break.conf
    [ "$(active "$guard")" = yes ] || fail 'the guard is not active; nothing was changed'
    [ "$(active docker.service)" = yes ] || fail 'Docker is not running; nothing was changed'
    docker_needs_guard || fail 'Docker does not need the guard; nothing was changed'
    restored=no
    restore() {
      [ "$restored" = no ] || return 0
      restored=yes
      rm -f -- "$drop"
      rmdir -- "$dropdir" 2>/dev/null || true
      systemctl daemon-reload || true
      systemctl reset-failed "$guard" docker.service >/dev/null 2>&1 || true
      systemctl start "$guard" >>"$log" 2>&1 || true
      systemctl start docker.socket docker.service >>"$log" 2>&1 || true
    }
    trap restore EXIT
    trap 'exit 1' INT TERM HUP
    install -d -m 0755 "$dropdir"
    printf '[Service]\nExecStart=\nExecStart=/bin/false\n' >"$drop"
    systemctl daemon-reload
    step 'guard broken on purpose (a drop-in under /run makes it fail)'
    systemctl stop docker.socket docker.service >>"$log" 2>&1 || fail 'Docker would not stop'
    systemctl stop "$guard" >>"$log" 2>&1 || true
    step 'Docker and the guard stopped; starting Docker'
    if systemctl start docker.service >>"$log" 2>&1; then started=yes; else started=no; fi
    pause 3
    if [ "$started" = no ] && [ "$(active docker.service)" = no ]; then fact docker_refused yes; else fact docker_refused no; fi
    restore
    trap - EXIT INT TERM HUP
    step 'drop-in removed; guard and Docker started again'
    for _ in $(seq 1 60); do
      if [ "$(active docker.service)" = yes ] && all_up "$(compose_state "$egress")" && all_up "$(compose_state "$kokoro")" && [ "$(health)" = healthy ]; then break; fi
      pause 5
    done
    fact guard_active "$(active "$guard")"
    if guard_loaded; then fact guard_loaded yes; else fact guard_loaded no; fi
    fact docker_active "$(active docker.service)"
    fact egress_running "$(compose_state "$egress")"
    fact kokoro_running "$(compose_state "$kokoro")"
    fact gluetun_health "$(health)"
    ;;

  kill-switch)
    [ "$(docker inspect --format '{{.State.Running}}' "$gateway" 2>/dev/null || true)" = true ] || fail 'the gateway container is not running; nothing was changed'
    test_py=$(cat)
    [[ $test_py == *'def main'* ]] || fail 'no test on standard input'
    resume='import json,urllib.request as u;u.urlopen(u.Request("http://127.0.0.1:8000/v1/vpn/status",data=json.dumps({"status":"running"}).encode(),headers={"Content-Type":"application/json"},method="PUT"),timeout=10).read()'
    tunnel_on() { docker exec "$gateway" python -c "$resume" >>"$log" 2>&1 || true; }
    trap tunnel_on EXIT
    trap 'exit 1' INT TERM HUP
    set +e
    timeout 600 docker exec -i "$gateway" python - <<<"$test_py"
    rc=$?
    set -e
    [ "$rc" = 0 ] || fail "the test stopped (exit $rc); the tunnel was started again"
    ;;

  public-ip)
    v4=$(curl -4 -fsS --max-time 15 https://api.ipify.org 2>/dev/null || true)
    v6=$(curl -6 -fsS --max-time 15 https://api6.ipify.org 2>/dev/null || true)
    if [[ $v4 =~ ^[0-9.]+$ ]] && public "$v4"; then fact public_ipv4 "$v4"; else fact public_ipv4 none; fi
    if [[ $v6 == *:* ]] && public "$v6"; then fact public_ipv6 "$v6"; else fact public_ipv6 none; fi
    ports=$(ss -Hltn 2>/dev/null | awk '{ print $4 }' | sed -nE 's/^.*:([0-9]+)$/\1/p' | sort -un | paste -sd, -)
    fact tcp_ports "${ports:-none}"
    ;;

  probe)
    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' EXIT
    n=0
    while read -r addr port extra || [ -n "${addr:-}" ]; do
      n=$((n + 1))
      port=${port%$'\r'}
      if [ -n "${extra:-}" ] || ! public "$addr" || ! [[ $port =~ ^[0-9]{1,5}$ ]] || ((10#$port < 1 || 10#$port > 65535)); then
        fail "input line $n is not '<public address> <port>'"
      fi
      family=4
      [[ $addr == *:* ]] && family=6
      (if timeout 4 bash -c "exec 3<>/dev/tcp/$addr/$port" 2>/dev/null; then s=open; else s=closed; fi
        printf 'FACT probe_%s_%s %s\n' "$family" "$((10#$port))" "$s" >"$tmp/$n") &
    done
    wait
    for i in $(seq 1 "$n"); do cat "$tmp/$i"; done
    step "probed $n port(s) from the VPS"
    ;;
esac
