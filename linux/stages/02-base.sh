#!/usr/bin/env bash
# Stage 2d: the VPS base system (docs/RESTORE.md Stage 2).
#
#   02-base.sh run   <account> <tailnet IPv4>   set it up
#   02-base.sh check <account> <tailnet IPv4>   report it, change nothing
#
# windows/stages/02-vps.ps1 runs it as root (sudo -n) over SSH. Every step
# checks first and changes only what differs, so it is safe to run again.
# It prints 'STEP <text>' for what it did, 'WARN <text>', 'FACT <name>
# <value>' in check mode, and 'FAIL <text>' before exiting 1. It never
# prints a file's content; apt's output goes to $log.
#
# What it sets, as on the live VPS (read 7 October 2026):
#   - Docker Engine and the Compose plugin from Docker's apt repository
#     (deb822 docker.sources, the key checked against Docker's fingerprint)
#     at the live versions below, and nftables, iproute2, nginx, jq, curl,
#     gnupg, ufw and unattended-upgrades from Ubuntu's. No sqlite3: the live
#     VPS does not have it.
#   - Unattended upgrades on.
#   - net.ipv4.ip_nonlocal_bind = 1, so nginx, Docker and sshd can bind the
#     tailnet address at boot before tailscale0 has it.
#   - systemd-networkd keeps routing rules it did not create
#     (ManageForeignRoutingPolicyRules=no). By default it deletes them
#     whenever it restarts, and on 4 October 2026 an automatic update
#     restarted it and wiped the guard's rules, its IPv6 block (5265)
#     included. Added 10 October 2026.
#   - No IPv6 on the public interface (netplan: dhcp6 off, no router
#     advertisements, no link-local addresses). Tailscale keeps its own
#     IPv6 on tailscale0. Liam's call, 10 October 2026.
#   - ufw: deny incoming and routed, allow outgoing; allow everything on
#     tailscale0, and 41641/udp for Tailscale's direct connections. The
#     live Cloudflare rules belong to the separate website, not the stack.
#   - sshd: keys only, no root, listening on the tailnet address only. Done
#     last, after a check that this server's tailnet address is the one the
#     PC sees, so a wrong address cannot lock the PC out.
#
# CRIA_ROOT (tests only) puts every file it reads or writes under another
# folder.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

mode=${1:-}
user=${2:-}
tsip=${3:-}
root=${CRIA_ROOT:-}
log=$root/var/log/ollama-cria/stage-02.log

# Docker's release key, and the versions on the live VPS.
docker_fpr=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
docker_pins=(
  'docker-ce=5:29.8.2-1~ubuntu.24.04~noble'
  'docker-ce-cli=5:29.8.2-1~ubuntu.24.04~noble'
  'containerd.io=2.3.6-1~ubuntu.24.04~noble'
  'docker-buildx-plugin=0.37.1-1~ubuntu.24.04~noble'
  'docker-compose-plugin=5.6.0-1~ubuntu.24.04~noble'
)
ubuntu_packages=(nftables iproute2 nginx jq unattended-upgrades ufw)

step() { printf 'STEP %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
fact() { printf 'FACT %s %s\n' "$1" "$2"; }
fail() { printf 'FAIL %s\n' "$*"; exit 1; }

case "$mode" in run | check) ;; *) fail "usage: 02-base.sh run|check <account> <tailnet IPv4>" ;; esac
[[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || fail 'not an account name'
[[ $tsip =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || fail 'not a tailnet IPv4 address'
[ "$(id -u)" = 0 ] || fail 'run as root (sudo -n)'

# shellcheck disable=SC1091
. "$root/etc/os-release"
if [ "${ID:-}" != ubuntu ] || [ "${VERSION_ID:-}" != 24.04 ]; then fail "expected Ubuntu 24.04, found ${PRETTY_NAME:-something else}"; fi
id "$user" >/dev/null 2>&1 || fail "there is no account $user; paste the bootstrap first"
mine=$(tailscale ip -4 2>/dev/null | head -n 1 || true)
[ "$mine" = "$tsip" ] || fail 'this server'"'"'s tailnet IPv4 is not the one the PC sees for it; is this the right server, and is it signed in to Tailscale?'

# yes or no: does the input hold a line grep matches with these arguments?
has() { if grep -q "$@"; then echo yes; else echo no; fi; }

# Does networkd keep routing rules it did not create? Reads its effective
# configuration (networkd.conf and every drop-in, in systemd's order), so a
# later drop-in that turns it back on counts.
networkd_keeps_rules() {
  systemd-analyze ${root:+--root="$root"} cat-config systemd/networkd.conf 2>/dev/null | awk '
    /^[[:space:]]*\[/ { section = $0; gsub(/[[:space:]]/, "", section); next }
    section == "[Network]" && /^[[:space:]]*ManageForeignRoutingPolicyRules[[:space:]]*=/ {
      v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); value = tolower(v)
    }
    END { exit !(value == "no" || value == "false" || value == "off" || value == "0") }'
}

installed() { [ "$(dpkg-query -W -f '${Status}' "$1" 2>/dev/null || true)" = 'install ok installed' ]; }
version_of() { dpkg-query -W -f '${Version}' "$1" 2>/dev/null || true; }

# Writes $2 plus a newline to $1 with mode $3 when it differs. Returns 0 when
# it wrote, 1 when the file already held exactly that.
put() {
  local path=$root$1 tmp
  install -d -m 0755 "$(dirname -- "$path")"
  tmp=$(mktemp -- "$path.cria.XXXXXX")
  printf '%s\n' "$2" > "$tmp"
  if [ -f "$path" ] && cmp -s -- "$tmp" "$path"; then rm -f -- "$tmp"; return 1; fi
  chmod "$3" -- "$tmp"
  mv -f -- "$tmp" "$path"
}

docker_key_ok() {
  # grep reads everything (no -q), so pipefail never sees a broken pipe.
  [ -s "$1" ] && gpg --show-keys --with-colons "$1" 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }' | grep -x "$docker_fpr" >/dev/null
}

docker_sources='Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc'

networkd_dropin=/etc/systemd/networkd.conf.d/10-ollama-cria.conf
networkd_conf="# ollama-cria Stage 2: keep the guard's routing rules when networkd restarts.
[Network]
ManageForeignRoutingPolicyRules=no"

netplan_dropin=/etc/netplan/60-ollama-cria.yaml
netplan_conf='# ollama-cria Stage 2: no IPv6 on the public interface (Liam, 10 October 2026).
# Tailscale keeps its own IPv6 on tailscale0.
network:
  version: 2
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp6: false
      accept-ra: false
      link-local: []'

sshd_conf="# ollama-cria Stage 2, as on the live VPS: keys only, no root, tailnet only.
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
PermitRootLogin no
ListenAddress $tsip
X11Forwarding no"

# ---------- check: facts only ----------

if [ "$mode" = check ]; then
  fact tailscale-ip match
  v=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)
  fact docker "${v:-none}"
  fact compose "$(docker compose version --short 2>/dev/null || echo none)"
  for p in "${ubuntu_packages[@]}"; do installed "$p" || fact missing "$p"; done
  fact nonlocal-bind "$(sysctl -n net.ipv4.ip_nonlocal_bind 2>/dev/null || echo unknown)"
  if networkd_keeps_rules; then fact networkd-keeps-rules yes; else fact networkd-keeps-rules no; fi
  if grep -qx '      dhcp6: false' "$root$netplan_dropin" 2>/dev/null && grep -qx '      link-local: \[\]' "$root$netplan_dropin"; then fact ipv6-public-off yes; else fact ipv6-public-off no; fi
  s=$(ufw status verbose 2>/dev/null || true)
  if grep -q '^Status: active' <<<"$s"; then fact ufw active; else fact ufw inactive; fi
  fact ufw-defaults "$(has '^Default: deny (incoming), allow (outgoing), deny (routed)' <<<"$s")"
  fact ufw-tailscale0 "$(has -E '^Anywhere on tailscale0 +ALLOW IN +Anywhere' <<<"$s")"
  fact ufw-41641 "$(has -E '^41641/udp +ALLOW IN +Anywhere' <<<"$s")"
  # Any other rule that lets something in from anywhere but tailscale0.
  n=$(grep -E 'ALLOW IN' <<<"$s" | grep -vE 'on tailscale0|^41641/udp' | grep -c . || true)
  fact ufw-other-allow "$n"
  # Listening TCP sockets on port 22, by address.
  l=$(ss -Hltn 'sport = :22' 2>/dev/null | awk '{ print $4 }' | sed 's/:22$//' | sort -u | tr '\n' ' ')
  if [ "$l" = "$tsip " ]; then fact ssh-listen tailnet-only; else fact ssh-listen other; fi
  t=$(sshd -T 2>/dev/null || true)
  fact ssh-password-off "$(has -x 'passwordauthentication no' <<<"$t")"
  fact ssh-root-off "$(has -x 'permitrootlogin no' <<<"$t")"
  exit 0
fi

# ---------- run ----------

install -d -m 0755 "$(dirname -- "$log")"
apt_updated=no
apt_update() {
  [ "$apt_updated" = yes ] && return 0
  apt-get update -q >>"$log" 2>&1 || fail "apt-get update failed (see /var/log/ollama-cria/stage-02.log on the VPS)"
  apt_updated=yes
}

# Tools the next steps use.
need=()
for p in ca-certificates curl gnupg; do installed "$p" || need+=("$p"); done
if [ ${#need[@]} -gt 0 ]; then
  apt_update
  apt-get install -y -q "${need[@]}" >>"$log" 2>&1 || fail "could not install ${need[*]} (see the log on the VPS)"
  step "installed ${need[*]}"
fi

# Docker's apt repository, with its key checked.
keyring=$root/etc/apt/keyrings/docker.asc
install -d -m 0755 "$root/etc/apt/keyrings"
if ! docker_key_ok "$keyring"; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$keyring.new" || fail "could not download Docker's apt key"
  if ! docker_key_ok "$keyring.new"; then rm -f -- "$keyring.new"; fail "Docker's apt key does not have Docker's fingerprint; stopped"; fi
  chmod 0644 -- "$keyring.new"
  mv -f -- "$keyring.new" "$keyring"
  step "Docker's apt key installed (fingerprint checked)"
fi
if put /etc/apt/sources.list.d/docker.sources "$docker_sources" 0644; then
  apt_updated=no
  step "Docker's apt repository added"
fi

# Packages: Docker at the live versions, the rest from Ubuntu.
need=()
for pin in "${docker_pins[@]}"; do
  p=${pin%%=*}
  if installed "$p"; then
    [ "$(version_of "$p")" = "${pin#*=}" ] || warn "$p is at $(version_of "$p"), not ${pin#*=} as on the live VPS; left as it is"
  else
    need+=("$pin")
  fi
done
for p in "${ubuntu_packages[@]}"; do installed "$p" || need+=("$p"); done
if [ ${#need[@]} -gt 0 ]; then
  apt_update
  apt-get install -y -q "${need[@]}" >>"$log" 2>&1 || fail "could not install ${need[*]} (see /var/log/ollama-cria/stage-02.log on the VPS)"
  step "installed ${need[*]}"
fi
systemctl is-enabled --quiet docker 2>/dev/null || { systemctl enable --quiet docker; step 'Docker enabled at boot'; }
systemctl is-active --quiet docker 2>/dev/null || { systemctl start docker; step 'Docker started'; }

# Unattended upgrades on.
if put /etc/apt/apt.conf.d/20auto-upgrades 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' 0644; then
  step 'unattended upgrades on'
fi

# Binding the tailnet address before tailscale0 has it.
if put /etc/sysctl.d/99-nginx-tailnet-bind.conf 'net.ipv4.ip_nonlocal_bind = 1' 0644; then
  step 'net.ipv4.ip_nonlocal_bind = 1 (99-nginx-tailnet-bind.conf)'
fi
if [ "$(sysctl -n net.ipv4.ip_nonlocal_bind 2>/dev/null || echo 0)" != 1 ]; then
  sysctl -q -p "$root/etc/sysctl.d/99-nginx-tailnet-bind.conf" >/dev/null || fail 'could not apply net.ipv4.ip_nonlocal_bind'
  step 'net.ipv4.ip_nonlocal_bind applied'
fi

# networkd reads this when it next starts, which is the moment it would
# otherwise delete the guard's rules, so it needs no restart now.
if put "$networkd_dropin" "$networkd_conf" 0644; then
  step "systemd-networkd keeps the guard's routing rules (10-ollama-cria.conf)"
fi

# No IPv6 on the public interface. netplan writes it for networkd's next
# start (no 'netplan apply', which would reconfigure the link under this
# SSH session); sysctl switches it off on each public interface now.
if put "$netplan_dropin" "$netplan_conf" 0600; then
  netplan generate >>"$log" 2>&1 || fail 'netplan rejected 60-ollama-cria.yaml (see the log on the VPS)'
  step 'no IPv6 on the public interface (60-ollama-cria.yaml)'
fi
for d in "$root"/proc/sys/net/ipv6/conf/en*; do
  [ -f "$d/disable_ipv6" ] || continue
  if [ "$(cat "$d/disable_ipv6")" != 1 ]; then
    sysctl -q -w "net.ipv6.conf.${d##*/}.disable_ipv6=1" >/dev/null || fail "could not switch IPv6 off on ${d##*/}"
    step "IPv6 switched off on ${d##*/}"
  fi
done

# Firewall, as on the live VPS. The SSH session that runs this comes in on
# tailscale0, which is allowed before ufw is switched on.
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw default deny routed >/dev/null
ufw allow in on tailscale0 comment 'Tailscale tailnet - full trust' >/dev/null
ufw allow 41641/udp comment 'Tailscale NAT traversal' >/dev/null
if ! grep -q '^Status: active' <<<"$(ufw status 2>/dev/null || true)"; then
  ufw --force enable >/dev/null
  step 'ufw on: deny incoming; allow tailscale0 and 41641/udp'
else
  step 'ufw rules checked'
fi

# sshd last. 00- sorts before cloud-init's drop-ins, so these values win.
dropin=/etc/ssh/sshd_config.d/00-liam-hardening.conf
before=$(mktemp)
had=no
if [ -f "$root$dropin" ]; then cp -p -- "$root$dropin" "$before"; had=yes; fi
if put "$dropin" "$sshd_conf" 0644; then
  if ! sshd -t >>"$log" 2>&1; then
    if [ "$had" = yes ]; then cp -p -- "$before" "$root$dropin"; else rm -f -- "$root$dropin"; fi
    rm -f -- "$before"
    fail 'sshd rejected the new settings; the old ones are back'
  fi
  systemctl daemon-reload
  # Ubuntu 24.04 listens through ssh.socket, which reads ListenAddress when
  # it is generated; sessions already open stay up.
  if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then systemctl restart ssh.socket; else systemctl reload ssh; fi
  step 'sshd: keys only, no root login, tailnet address only'
fi
rm -f -- "$before"

printf 'FACT docker %s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo none)"
