#!/bin/bash
# Stage 2a: paste into the new VPS's console as root (docs/RESTORE.md Stage 2).
# windows/stages/02-vps.ps1 writes this file into the staging folder with
# the PC's public key and the stack account filled in. It creates the
# account with passwordless sudo, lets the PC's key in, installs Tailscale
# from Tailscale's apt repository and prints the host key fingerprint to
# give the controller. Safe to paste twice.
set -eu
U='{{USER}}'
K='{{PUBLIC_KEY}}'
id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo "$U"
install -d -m 700 -o "$U" -g "$U" "/home/$U/.ssh"
f="/home/$U/.ssh/authorized_keys"
touch "$f" && chown "$U:$U" "$f" && chmod 600 "$f"
grep -qxF "$K" "$f" || printf '%s\n' "$K" >> "$f"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$U" > /etc/sudoers.d/90-ollama-cria
chmod 440 /etc/sudoers.d/90-ollama-cria && visudo -cq
curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg -o /usr/share/keyrings/tailscale-archive-keyring.gpg
echo 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu noble main' > /etc/apt/sources.list.d/tailscale.list
apt-get update -qq && apt-get install -y -qq tailscale
systemctl enable --now tailscaled
echo; echo 'Give the controller this host key fingerprint (the SHA256:... part):'
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
echo; echo 'Next: delete the old {{NODE}} node in the Tailscale admin console, then run:'
echo '  tailscale up --hostname={{NODE}}'
