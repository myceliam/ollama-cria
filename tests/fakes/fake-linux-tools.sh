#!/usr/bin/env bash
# Test stand-in for the system tools linux/stages/*.sh call, used by
# tests/Linux-Stages.Tests.ps1. That test puts one wrapper per tool on PATH,
# each running: bash fake-linux-tools.sh <tool> <arguments>. Every call is
# logged to $CRIA_ROOT/fake/calls; the machine's state lives in files under
# $CRIA_ROOT/fake, which the tests set up and read.
set -u
tool=$1
shift
f=$CRIA_ROOT/fake
mkdir -p "$f"
printf '%s %s\n' "$tool" "$*" >> "$f/calls"
has() { [ -f "$f/$1" ] && grep -qxF -- "$2" "$f/$1"; }
add() { has "$1" "$2" || printf '%s\n' "$2" >> "$f/$1"; }
drop() { [ -f "$f/$1" ] && grep -vxF -- "$2" "$f/$1" > "$f/$1.new"; [ -f "$f/$1.new" ] && mv "$f/$1.new" "$f/$1"; return 0; }
# Stage 10's guard-break drop-in: while it exists the guard fails, so
# Docker (which Requires= it) does not start.
broken=$CRIA_ROOT/run/systemd/system/owui-web-egress-guard.service.d/zz-ollama-cria-break.conf

case "$tool" in
  id)
    if [ "${1:-}" = -u ]; then echo 0; exit 0; fi
    has users "$1"
    ;;
  tailscale)
    [ "$*" = 'ip -4' ] && cat "$f/tailscale-ip" 2>/dev/null
    ;;
  dpkg-query)
    pkg=${*: -1}
    line=$(grep -m1 "^$pkg " "$f/installed" 2>/dev/null) || exit 1
    case "$*" in
      *Status*) printf 'install ok installed' ;;
      *Version*) printf '%s' "${line#* }" ;;
    esac
    ;;
  apt-get)
    [ -f "$f/apt-fails" ] && exit 100
    if [ "$1" = install ]; then
      for a in "$@"; do
        case "$a" in -*|install) continue ;; esac
        p=${a%%=*}; v=${a#*=}; [ "$v" = "$a" ] && v=ubuntu
        add installed "$p $v"
      done
    fi
    ;;
  curl)
    case " $* " in
      *'%{http_code}'*)
        # 09-reach.sh: the status in fake/reach-<port>, else nothing answers.
        url="${*: -1}"; port=${url##*:}; port=${port%%/*}
        if [ -f "$f/reach-$port" ]; then cat "$f/reach-$port"; else printf 000; exit 7; fi
        ;;
      *' -o '*) cp "$f/download" "${*: -1}" ;;
      *api.ipify.org*) cat "$f/host-ip" 2>/dev/null || exit 7 ;;
      *api6.ipify.org*) cat "$f/host-ip6" 2>/dev/null || exit 7 ;;
    esac
    ;;
  chown) ;;
  nft)
    [ -f "$f/guard-loaded" ]
    ;;
  ip)
    # guard-v6-missing: the IPv4 rules are there but the IPv6 block is not.
    [ -f "$f/guard-loaded" ] || exit 0
    # guard-v6-scoped: rule 5265 blocks only one range, not everything.
    if [ "${1:-}" = -6 ]; then
      if [ -f "$f/guard-v6-scoped" ]; then printf '5264:\tfrom all lookup main\n5265:\tfrom 2001:db8::/32 prohibit\n'
      elif [ ! -f "$f/guard-v6-missing" ]; then printf '5264:\tfrom all lookup main\n5265:\tfrom all prohibit\n'; fi
    else
      printf '5260:\tfrom all lookup 52\n5264:\tfrom all lookup main\n'
    fi
    exit 0
    ;;
  nginx)
    exit "$(cat "$f/nginx-t" 2>/dev/null || echo 0)"
    ;;
  netplan)
    [ ! -f "$f/netplan-fails" ]
    ;;
  systemd-analyze)
    # cat-config: networkd.conf, then its drop-ins in name order.
    cat "$CRIA_ROOT/etc/systemd/networkd.conf" "$CRIA_ROOT"/etc/systemd/networkd.conf.d/*.conf 2>/dev/null
    exit 0
    ;;
  gpg)
    if grep -q GOOD-KEY "${*: -1}"; then
      echo 'fpr:::::::::9DC858229FC7DD38854AE2D88D81803C0EBFCD88:'
      echo 'fpr:::::::::D3306A018370199E527AE7997EA0A9C3F273FCD8:'
    else
      echo 'fpr:::::::::0000000000000000000000000000000000000000:'
    fi
    ;;
  systemctl)
    case "$1" in
      is-enabled) has enabled "${*: -1}" ;;
      is-active) has active "${*: -1}" ;;
      enable) add enabled "${*: -1}" ;;
      start | restart | reload)
        shift
        for u in "$@"; do
          case "$u" in -*) continue ;; esac
          if [ "$u" = owui-web-egress-guard.service ]; then
            { [ -f "$f/guard-fails" ] || [ -f "$broken" ]; } && exit 1
            [ -f "$f/guard-empty" ] || touch "$f/guard-loaded"
          fi
          if [ "$u" = docker.service ] && [ -f "$broken" ] && [ ! -f "$f/docker-ignores-guard" ]; then exit 1; fi
          add active "$u"
        done
        ;;
      stop)
        shift
        for u in "$@"; do drop active "$u"; done
        ;;
      reset-failed) ;;
      show)
        if [ "${*: -1}" = --value ]; then
          case "$*" in
            *ActiveEnterTimestampMonotonic*) cat "$f/guard-mono" 2>/dev/null || echo 0 ;;
            *ExecMainStartTimestampMonotonic*) cat "$f/docker-mono" 2>/dev/null || echo 0 ;;
          esac
          exit 0
        fi
        if [ -f "$CRIA_ROOT/etc/systemd/system/docker.service.d/owui-web-egress.conf" ] && [ ! -f "$f/dropin-inactive" ]; then
          echo 'Requires=docker.socket owui-web-egress-guard.service'
          echo 'After=network-online.target owui-web-egress-guard.service'
        else
          echo 'Requires=docker.socket'
          echo 'After=network-online.target'
        fi
        ;;
      daemon-reload) ;;
    esac
    ;;
  sysctl)
    if [ "$1" = -n ]; then cat "$f/nonlocal" 2>/dev/null || echo 0
    else echo 1 > "$f/nonlocal"; fi
    ;;
  ufw)
    case "$1" in
      status)
        if [ -f "$f/ufw-active" ]; then echo 'Status: active'; else echo 'Status: inactive'; exit 0; fi
        if [ "${2:-}" = verbose ]; then
          echo 'Logging: on (low)'
          d=$(cat "$f/ufw-defaults" 2>/dev/null)
          echo "Default: $d"
          echo 'New profiles: skip'
          echo
        fi
        echo 'To                         Action      From'
        echo '--                         ------      ----'
        cat "$f/ufw-rules" 2>/dev/null
        ;;
      default)
        d=$(cat "$f/ufw-defaults" 2>/dev/null || echo 'allow (incoming), allow (outgoing), allow (routed)')
        d=$(sed -E "s/[a-z]+ \($3\)/$2 ($3)/" <<<"$d")
        echo "$d" > "$f/ufw-defaults"
        ;;
      allow)
        if [ "$2" = in ]; then add ufw-rules "Anywhere on $4             ALLOW IN    Anywhere"
        else add ufw-rules "$2                  ALLOW IN    Anywhere"; fi
        ;;
      --force) touch "$f/ufw-active" ;;
    esac
    ;;
  sshd)
    if [ "$1" = -t ]; then exit "$(cat "$f/sshd-t" 2>/dev/null || echo 0)"; fi
    d=$CRIA_ROOT/etc/ssh/sshd_config.d/00-liam-hardening.conf
    if [ -f "$d" ]; then printf 'passwordauthentication no\npermitrootlogin no\n'; else printf 'passwordauthentication yes\npermitrootlogin yes\n'; fi
    ;;
  docker)
    case "$1" in
      version) cat "$f/docker-version" 2>/dev/null || exit 1 ;;
      pull) [ -f "$f/pull-fails" ] && exit 1; ref=${*: -1}; add images "$ref sha256:${ref##*:}" ;;
      tag) id=$(awk -v r="$2" '$1 == r { print $2 }' "$f/images"); add images "$3 $id" ;;
      build) [ -f "$f/build-fails" ] && exit 1; add images "$4 sha256:built-$4" ;;
      image)
        line=$(awk -v r="${*: -1}" '$1 == r' "$f/images" 2>/dev/null)
        [ -n "$line" ] || exit 1
        case "$*" in *--format*) echo "${line#* }" ;; esac
        ;;
      inspect)
        case "$*" in
          *State.Running*) cat "$f/gateway-running" 2>/dev/null || echo true ;;
          *) cat "$f/gluetun-health" 2>/dev/null || echo healthy ;;
        esac
        ;;
      exec)
        case " $* " in
          # 10-vps.sh kill-switch: the test arrives on stdin.
          *' -i '*) cat > "$f/killswitch-in"; cat "$f/killswitch-out" 2>/dev/null; exit "$(cat "$f/killswitch-exit" 2>/dev/null || echo 0)" ;;
          *vpn/status*) touch "$f/tunnel-resumed" ;;
          *) cat "$f/tunnel-ip" 2>/dev/null || exit 1 ;;
        esac
        ;;
      compose)
        [ "$*" = 'compose version --short' ] && { echo 5.6.0; exit 0; }
        dir=$(basename "$3")
        case " $* " in
          *' up '*) [ -f "$f/up-fails-$dir" ] && exit 1; touch "$f/up-$dir" ;;
          *' ps '*)
            [ -f "$f/up-$dir" ] || exit 0
            case " $* " in
              *' running '*) cat "$f/running-$dir" 2>/dev/null || cat "$f/services-$dir" ;;
              *) cat "$f/services-$dir" ;;
            esac
            ;;
        esac
        ;;
    esac
    ;;
  ss)
    if [[ $* != *sport* ]]; then
      # Every listening socket: one line per address in each listen-<port>.
      for src in "$f"/listen-* "$f/ssh-listen"; do
        [ -f "$src" ] || continue
        port=${src##*listen-}; [ "$src" = "$f/ssh-listen" ] && port=22
        while read -r a; do echo "LISTEN 0 4096 $a:$port 0.0.0.0:*"; done < "$src"
      done
      exit 0
    fi
    port=${*: -1}
    port=${port##*:}
    src=$f/listen-$port
    [ "$port" = 22 ] && src=$f/ssh-listen
    [ -f "$src" ] || exit 0
    while read -r a; do echo "LISTEN 0 4096 $a:$port 0.0.0.0:*"; done < "$src"
    ;;
  systemd-run) touch "$f/reboot-scheduled" ;;
  timeout)
    case "${*: -1}" in
      # 10-vps.sh probe: a port is open when fake/tcp-open-<port> exists.
      */dev/tcp/*) port=${*: -1}; port=${port##*/}; [ -f "$f/tcp-open-$port" ] ;;
      *) shift; exec "$@" ;;
    esac
    ;;
  *)
    echo "fake-linux-tools: no fake for $tool" >&2
    exit 127
    ;;
esac
