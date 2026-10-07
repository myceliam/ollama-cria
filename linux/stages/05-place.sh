#!/usr/bin/env bash
# Stage 5: put the rendered VPS files in place (docs/RESTORE.md Stage 5).
#
#   05-place.sh <account>
#
# windows/stages/05-vps.ps1 runs it as root (sudo -n) over SSH, with one
# file per input line:
#
#   <path, base64> <mode> <owner> <SHA-256> <content, base64>
#
# and it prints one line per file: 'PLACED new|same|replaced <path>' or
# 'FAIL <path>: <why>', then exits 1 if any file failed. It never prints
# content.
#
# Rules:
#   - Only under /home/<account>/, /etc/systemd/system/ and
#     /etc/nginx/sites-available/; never through a symbolic link.
#   - Written to a temporary file beside the target, checked against its
#     SHA-256, given its mode and owner, then moved into place.
#   - A file already there is left when it is the same, replaced only when
#     this script wrote it and nobody changed it since (the ledger in
#     /var/lib/ollama-cria/placed), and refused otherwise.
#
# CRIA_ROOT (tests only) puts every path under another folder.
set -euo pipefail

user=${1:-}
root=${CRIA_ROOT:-}
[[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo 'FAIL usage: 05-place.sh <account>'; exit 1; }
[ "$(id -u)" = 0 ] || { echo 'FAIL run as root (sudo -n)'; exit 1; }

ledger=$root/var/lib/ollama-cria/placed
install -d -m 0700 "$(dirname -- "$ledger")"
[ -f "$ledger" ] || install -m 0600 /dev/null "$ledger"

failed=0
say_fail() { printf 'FAIL %s: %s\n' "$1" "$2"; failed=1; }

allowed() {
  case "$1" in
    /home/"$user"/?* | /etc/systemd/system/?* | /etc/nginx/sites-available/?*) ;;
    *) return 1 ;;
  esac
  case "$1/" in */../* | */./* | *//*) return 1 ;; esac
  return 0
}

# Creates the folders above $1 that are missing, owned by $2, and fails if
# any folder on the way is a symbolic link.
make_parents() {
  local dir q='' part
  dir=$(dirname -- "$1")
  IFS=/ read -r -a parts <<<"${dir#/}"
  for part in "${parts[@]}"; do
    q="$q/$part"
    if [ -L "$root$q" ]; then return 2; fi
    if [ ! -e "$root$q" ]; then
      mkdir -m 0755 -- "$root$q"
      chown -- "$2:$2" "$root$q"
    elif [ ! -d "$root$q" ]; then
      return 3
    fi
  done
}

ledger_sha() { awk -v p="$1" '$2 == p { s = $1 } END { print s }' "$ledger"; }

ledger_set() {
  local tmp
  tmp=$(mktemp -- "$ledger.XXXXXX")
  awk -v p="$2" '$2 != p' "$ledger" > "$tmp"
  printf '%s %s\n' "$1" "$2" >> "$tmp"
  chmod 0600 -- "$tmp"
  mv -f -- "$tmp" "$ledger"
}

while IFS=' ' read -r pb64 mode owner want cb64 || [ -n "${pb64:-}" ]; do
  cb64=${cb64%$'\r'}
  [ -n "$pb64" ] || continue
  path=$(printf '%s' "$pb64" | base64 -d 2>/dev/null) || { say_fail '?' 'the path did not decode'; continue; }
  allowed "$path" || { say_fail "$path" 'not a place this stage writes'; continue; }
  [[ $mode =~ ^0[0-7]{3}$ ]] || { say_fail "$path" 'bad mode'; continue; }
  [[ $owner =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { say_fail "$path" 'bad owner'; continue; }
  [[ $want =~ ^[0-9a-f]{64}$ ]] || { say_fail "$path" 'bad SHA-256'; continue; }
  rc=0
  make_parents "$path" "$owner" || rc=$?
  if [ "$rc" = 2 ]; then say_fail "$path" 'a symbolic link on the way'; continue; fi
  if [ "$rc" != 0 ]; then say_fail "$path" 'a folder on the way is something else'; continue; fi
  target=$root$path
  if [ -L "$target" ]; then say_fail "$path" 'a symbolic link is there'; continue; fi
  if [ -e "$target" ] && [ ! -f "$target" ]; then say_fail "$path" 'something other than a file is there'; continue; fi

  tmp=$(mktemp -- "$(dirname -- "$target")/.cria-place.XXXXXX")
  if ! printf '%s' "$cb64" | base64 -d > "$tmp" 2>/dev/null; then rm -f -- "$tmp"; say_fail "$path" 'the content did not decode'; continue; fi
  got=$(sha256sum -- "$tmp" | awk '{ print $1 }')
  if [ "$got" != "$want" ]; then rm -f -- "$tmp"; say_fail "$path" 'the content arrived changed'; continue; fi
  chmod "$mode" -- "$tmp"
  chown -- "$owner:$owner" "$tmp"

  if [ -e "$target" ]; then
    now=$(sha256sum -- "$target" | awk '{ print $1 }')
    if [ "$now" = "$want" ]; then
      rm -f -- "$tmp"
      chmod "$mode" -- "$target"
      chown -- "$owner:$owner" "$target"
      ledger_set "$want" "$path"
      echo "PLACED same $path"
      continue
    fi
    if [ "$(ledger_sha "$path")" != "$now" ]; then
      rm -f -- "$tmp"
      say_fail "$path" 'a different file is already there, not one this stage wrote; move it away and run again'
      continue
    fi
    mv -f -- "$tmp" "$target"
    ledger_set "$want" "$path"
    echo "PLACED replaced $path"
  else
    mv -- "$tmp" "$target"
    ledger_set "$want" "$path"
    echo "PLACED new $path"
  fi
done

exit "$failed"
