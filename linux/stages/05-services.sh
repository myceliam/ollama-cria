#!/usr/bin/env bash
# Stage 5: the guard, images and services on the VPS (docs/RESTORE.md
# Stage 5a to 5e).
#
#   05-services.sh run   <account> <tailnet IPv4> [guard-changed]
#   05-services.sh check <account> <tailnet IPv4>
#
# run starts everything; check reports it and changes nothing.
# guard-changed says 05-place.sh has just written one of the guard's files,
# so a guard already running restarts to load them.
#
# windows/stages/05-vps.ps1 runs it as root (sudo -n) over SSH, after
# 05-place.sh has put the files in place. In run mode it reads the images
# to get ready, one per input line:
#
#   pull <reference with digest> <tag to give it, or ->
#   build <tag> <build folder>
#
# It prints 'STEP', 'WARN', 'FACT <name> <value>' (check mode) and
# 'FAIL <text>' lines, the same way as 02-base.sh, and never prints the
# content of a file, an address or a secret. Long output goes to $log.
#
# Order (C-20, C-43): the guard is loaded and proved (its nftables table
# and routing rules exist) and Docker is made to depend on it before any
# image is pulled or container created. The guard is restarted only when
# it has to be: Docker Requires= it, and systemd restarts Docker, with
# every container, whenever the guard restarts (systemd.unit(5)). Then every image is pulled at its
# digest or built, and only then do the compose projects start, with
# --pull never so nothing else is fetched.
#
# CRIA_ROOT (tests only) puts every file it reads or writes under another
# folder.
set -euo pipefail

mode=${1:-}
user=${2:-}
tsip=${3:-}
changed=${4:-}
root=${CRIA_ROOT:-}
home=/home/$user
egress=$home/owui-web-egress
kokoro=$home/kokoro
guard=owui-web-egress-guard.service
log=$root/var/log/ollama-cria/stage-05.log

step() { printf 'STEP %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
fact() { printf 'FACT %s %s\n' "$1" "$2"; }
fail() { printf 'FAIL %s\n' "$*"; exit 1; }
has() { if grep -q "$@"; then echo yes; else echo no; fi; }

case "$mode" in run | check) ;; *) fail 'usage: 05-services.sh run|check <account> <tailnet IPv4>' ;; esac
[[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || fail 'not an account name'
[[ $tsip =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || fail 'not a tailnet IPv4 address'
case "$changed" in '' | guard-changed) ;; *) fail "unknown option: $changed" ;; esac
[ "$(id -u)" = 0 ] || fail 'run as root (sudo -n)'

# Loaded: the nftables table, rule 5260 and the IPv6 block, rule 5265.
guard_loaded() {
  nft list table inet owui_web >/dev/null 2>&1 &&
    [ "$(ip -4 rule show | grep -c '^5260:' || true)" -ge 1 ] &&
    [ "$(ip -6 rule show | grep -cE '^5265:[[:space:]]+from all prohibit$' || true)" -ge 1 ]
}
docker_needs_guard() {
  local s
  s=$(systemctl show docker -p Requires -p After 2>/dev/null || true)
  [ "$(grep -c "$guard" <<<"$s" || true)" -ge 2 ]
}

# The addresses a TCP port listens on: tailnet-only, other, or none.
listening() {
  local a
  a=$(ss -Hltn "sport = :$1" 2>/dev/null | awk '{ print $4 }' | sed -E 's/:[0-9]+$//' | sort -u | tr '\n' ' ')
  if [ -z "$a" ]; then echo none; elif [ "$a" = "$tsip " ]; then echo tailnet-only; else echo other; fi
}

compose() { docker compose --project-directory "$root$1" "${@:2}"; }

# 'running/total' for a compose project.
compose_state() {
  local all up
  all=$(compose "$1" ps -a --format '{{.Service}}' 2>/dev/null | grep -c . || true)
  up=$(compose "$1" ps --status running --format '{{.Service}}' 2>/dev/null | grep -c . || true)
  echo "$up/$all"
}

# ---------- check: facts only ----------

if [ "$mode" = check ]; then
  if systemctl is-enabled --quiet "$guard" 2>/dev/null; then fact guard-enabled yes; else fact guard-enabled no; fi
  if systemctl is-active --quiet "$guard" 2>/dev/null; then fact guard-active yes; else fact guard-active no; fi
  if nft list table inet owui_web >/dev/null 2>&1; then fact nft-table yes; else fact nft-table no; fi
  if [ "$(ip -4 rule show 2>/dev/null | has '^5260:')" = yes ] && [ "$(ip -6 rule show 2>/dev/null | has -E '^5265:[[:space:]]+from all prohibit$')" = yes ]; then fact ip-rule yes; else fact ip-rule no; fi
  if docker_needs_guard; then fact docker-needs-guard yes; else fact docker-needs-guard no; fi
  fact egress-running "$(compose_state "$egress")"
  fact gluetun-health "$(docker inspect --format '{{.State.Health.Status}}' vps-web-gluetun 2>/dev/null || echo missing)"
  fact kokoro-running "$(compose_state "$kokoro")"
  # The exit address from inside the tunnel's namespace against the
  # host's own; only whether they differ is printed.
  host_ip=$(curl -fsS --max-time 15 https://api.ipify.org 2>/dev/null || true)
  tunnel_ip=$(docker exec vps-web-brave-jina-gateway python -c "import urllib.request; print(urllib.request.urlopen('https://api.ipify.org', timeout=15).read().decode())" 2>/dev/null || true)
  if [ -z "$host_ip" ] || [ -z "$tunnel_ip" ]; then fact exit-ip unknown
  elif [ "$host_ip" = "$tunnel_ip" ]; then fact exit-ip same
  else fact exit-ip differs; fi
  fact listen-8880 "$(listening 8880)"
  fact listen-18099 "$(listening 18099)"
  fact listen-13100 "$(listening 13100)"
  if [ "$(readlink -- "$root/etc/nginx/sites-enabled/groq-relay" 2>/dev/null || true)" = /etc/nginx/sites-available/groq-relay ]; then fact nginx-site yes; else fact nginx-site no; fi
  if nginx -t >/dev/null 2>&1; then fact nginx-test ok; else fact nginx-test fail; fi
  exit 0
fi

# ---------- run ----------

install -d -m 0755 "$(dirname -- "$log")"
tun=$root/dev/net/tun
if [ -n "$root" ]; then [ -e "$tun" ] || tun=; else [ -c "$tun" ] || tun=; fi
[ -n "$tun" ] || fail '/dev/net/tun is missing; gluetun needs it (ask the provider to enable TUN)'
[ -f "$root$egress/.env" ] || fail "$egress/.env is missing; Stage 4 places it from bundle folder 05"
for f in "$egress/compose.yml" "$egress/guard.sh" "$egress/guard.nft" "$kokoro/compose.yml" /etc/systemd/system/$guard \
  /etc/systemd/system/docker.service.d/owui-web-egress.conf /etc/nginx/sites-available/groq-relay; do
  [ -f "$root$f" ] || fail "$f is missing; run Stage 5 again so it is placed first"
done

# 5a: the guard, proved loaded, and Docker made to need it.
systemctl daemon-reload
systemctl is-enabled --quiet "$guard" 2>/dev/null || { systemctl enable --quiet "$guard"; step "$guard enabled at boot"; }
didnt="$guard did not start (see /var/log/ollama-cria/stage-05.log and 'journalctl -u $guard')"
if ! systemctl is-active --quiet "$guard" 2>/dev/null; then
  systemctl start "$guard" >>"$log" 2>&1 || fail "$didnt"
  step "$guard started"
elif [ -n "$changed" ]; then
  systemctl restart "$guard" >>"$log" 2>&1 || fail "$didnt"
  step "$guard restarted to load its new files; Docker restarted with it"
elif ! guard_loaded; then
  systemctl restart "$guard" >>"$log" 2>&1 || fail "$didnt"
  step "$guard restarted: it was running without its rules; Docker restarted with it"
fi
guard_loaded || fail "the guard says it started, but its nftables table, routing rule 5260 or IPv6 block 5265 is missing; no container was started"
step 'guard: nftables table and routing rules loaded'
docker_needs_guard || fail "Docker does not need $guard yet (the drop-in is not active); no container was started"
step 'Docker needs the guard (Requires= and After=)'

# 5b: images, each at its digest or built from the repo's files.
while read -r kind a b || [ -n "${kind:-}" ]; do
  b=${b%$'\r'}
  case "$kind" in
    pull)
      [[ $a =~ @sha256:[0-9a-f]{64}$ ]] || fail "not a pinned image reference: $a"
      if ! docker image inspect "$a" >/dev/null 2>&1; then
        docker pull -q "$a" >>"$log" 2>&1 || fail "could not pull $a"
        step "pulled $a"
      fi
      if [ "$b" != - ] && [ "$(docker image inspect --format '{{.Id}}' "$b" 2>/dev/null || true)" != "$(docker image inspect --format '{{.Id}}' "$a")" ]; then
        docker tag "$a" "$b"
        step "tagged it $b"
      fi
      ;;
    build)
      if docker image inspect "$a" >/dev/null 2>&1; then continue; fi
      [ -f "$root$b/Dockerfile" ] || fail "no Dockerfile in $b"
      docker build -q -t "$a" "$root$b" >>"$log" 2>&1 || fail "could not build $a (see /var/log/ollama-cria/stage-05.log)"
      step "built $a from $b"
      ;;
    '') ;;
    *) fail "unknown image line: $kind" ;;
  esac
done

# 5c and 5d: the compose projects, with nothing else pulled. --wait holds
# until every service is running and healthy.
for project in "$egress" "$kokoro"; do
  if ! compose "$project" up -d --pull never --wait --wait-timeout 300 >>"$log" 2>&1; then
    fail "the compose project in $project did not come up healthy ($(compose_state "$project") running; see the log)"
  fi
  step "$project: $(compose_state "$project") services running"
done

# 5e: only the Groq relay site; the package's default site goes.
enabled=$root/etc/nginx/sites-enabled
install -d -m 0755 "$enabled"
if [ "$(readlink -- "$enabled/default" 2>/dev/null || true)" = /etc/nginx/sites-available/default ]; then
  rm -f -- "$enabled/default"
  step "nginx's default site switched off"
fi
if [ "$(readlink -- "$enabled/groq-relay" 2>/dev/null || true)" != /etc/nginx/sites-available/groq-relay ]; then
  if [ -e "$enabled/groq-relay" ] || [ -L "$enabled/groq-relay" ]; then fail "/etc/nginx/sites-enabled/groq-relay is something else already; move it away"; fi
  ln -s /etc/nginx/sites-available/groq-relay "$enabled/groq-relay"
  step 'nginx: Groq relay site switched on'
fi
nginx -t >>"$log" 2>&1 || fail 'nginx -t rejects the configuration (see the log)'
if systemctl is-active --quiet nginx 2>/dev/null; then systemctl reload nginx; else systemctl start nginx; fi
step 'nginx reloaded'
