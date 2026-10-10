# 🛰️ VPS rebuild: the agent's runbook

**For:** the AI assistant (Claude, ChatGPT or Antigravity) rebuilding Liam's VPS when **only the VPS is lost** and the PC still works.
**Pairs with:** [`VPS-REBUILD-HUMAN.md`](VPS-REBUILD-HUMAN.md), Liam's walkthrough of the same steps. Both use the step numbers V0 to V14.
**Not for:** a lost PC. Then start at [`START-HERE.md`](START-HERE.md).
**Last checked:** 8 October 2026. Never run for real yet: when a step goes differently, fix this file and the human one together.

---

## 0. 📏 Rules for this runbook

1. **Never see a secret.** Don't print, paste, read or ask Liam for one. In V8 Liam types the keys into the VPS himself; you only check their shape. Names, lengths, yes or no.
2. **Stop at every 👤 step.** Send Liam the 💬 text in that step, then wait for his answer. One question at a time.
3. **Say what you're about to do** in one line before each 🤖 step that changes the new VPS. Nothing here changes the PC's stack, except V12B, which needs Liam's yes.
4. **Keep Liam's progress copy current.** When a step passes, run `Set-StepDone V<n>` (V0 defines it) and tell Liam in one line which step passed and what comes next.
5. **A failed check stops the run.** Work through 🧯 under that step. If that doesn't fix it, tell Liam what failed and what you tried, then wait.
6. **Addresses stay in memory.** Keep tailnet and public addresses in variables, never in files, the progress copy or the repo. The helpers below pass them as arguments for that reason.
7. **The old server stays untouched.** If it still runs, Liam may power it off (V1). Nothing in this runbook logs in to it.

---

## 1. 🧭 What you are rebuilding

Every web search, page read and Brave call from Open WebUI leaves the internet from a Mullvad server in Zurich, two hops away from both of Liam's machines:

```text
PC: Open WebUI → web-vps-relay ──tailnet (WireGuard)──▶ VPS: gateway, SearXNG, Jina
                                                            │ one shared network
                                                            ▼
                                     gluetun ──WireGuard──▶ Mullvad entry se-sto-wg-202 (Stockholm)
                                                            ▼
                                                  Mullvad exit ch-zrh-wg-003 (Zurich) ──▶ Brave, websites
```

| Layer | What it does | Where it lives |
|---|---|---|
| Tailnet only | Every VPS service binds to the VPS's tailnet address. ufw denies all inbound except `tailscale0` and `41641/udp`. sshd listens on the tailnet address only | `vps/web-egress/compose.yml`, `vps/kokoro/compose.yml`, `vps/nginx/groq-relay`, `linux/stages/02-base.sh` |
| One tunnel | SearXNG, Jina Reader, the Brave/Jina gateway, searxng-mcp and the proxy relay share gluetun's network (`network_mode: service:gluetun`), so they have no route but the tunnel | `compose.yml` |
| Multihop | gluetun's `custom` provider. The endpoint is the **entry** server's address with the **exit** server's multihop port; the public key is the **exit** server's | `.env` (bundle folder 05), `compose.yml` |
| Kill switch 1 | gluetun's own firewall (`FIREWALL: on`): nothing leaves outside the tunnel. DNS goes over TLS inside it (`DOT: on`) | `compose.yml` |
| Kill switch 2 | The nftables guard, table `inet owui_web`. The egress subnet may reach only the tailnet and **one** plaintext destination, the WireGuard handshake to the entry server. IPv6 is rejected. Containers can't open new connections to the PC or reach the VPS host | `guard.nft`, `guard.sh`, `owui-web-egress-guard.service` |
| Boot order | Docker `Requires=` and `After=` the guard, so no container starts without it | `vps/systemd/docker.service.d/owui-web-egress.conf` |
| Not tunnelled, on purpose | Kokoro (needs no internet), the Groq STT relay (Groq refuses Mullvad addresses), SSH and Tailscale | |

**The egress `.env` has seven names:** `VPN_ENDPOINT_IP`, `VPN_ENDPOINT_PORT`, `WIREGUARD_PUBLIC_KEY`, `WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES`, `BRAVE_API_KEY`, `SEARXNG_SECRET`.

> ⚠️ **The entry server is written down twice.** `guard.nft` holds the entry address and port again, as its one handshake exception. If it and the `.env` disagree, the tunnel never comes up. Nothing leaks, because it fails closed, but web search stays down. V9 checks this.

---

## 2. 🗺️ The steps

| Step | Who | What |
|---|---|---|
| V0 | 🤖👤 | Confirm only the VPS is lost; one question; set up |
| V1 | 👤 | A new server with Ubuntu 24.04 |
| V2 | 🤖 | Write the bootstrap script |
| V3 | 👤 | Run it as root; read out the fingerprint |
| V4 | 👤 | Tailscale: the same name and the same address |
| V5 | 🤖 | Trust the new server's key |
| V6 | 🤖 | Base system: Docker, firewall, SSH on the tailnet only |
| V7 | 🤖 | Put the VPS files in place |
| V8 | 👤🤖 | The keys: saved ones (8A) or new ones (8B) |
| V9 | 🤖 | Check the WireGuard settings against the guard |
| V10 | 🤖 | The guard first, then images and services |
| V11 | 🤖 | Prove it: multihop, kill switches, nothing exposed |
| V12 | 🤖👤 | The PC side, and a test from Open WebUI |
| V13 | 🤖👤 | A new backup into Bitwarden |
| V14 | 🤖 | Log it and tidy up |

Every command below is PowerShell 7 (`pwsh`) on the PC, unless it says otherwise. The VPS is only ever reached through the helpers from V0, which run the repo's own scripts as root with `sudo -n`, exactly as the controller does.

---

## V0 · Confirm only the VPS is lost, then set up 🤖👤

**1. Check** that the VPS is gone and the PC's stack is fine:

```powershell
tailscale status | Select-String '\bvps\b'                                  # offline, or missing
ssh -o BatchMode=yes -o ConnectTimeout=10 vps true; "ssh exit code: $LASTEXITCODE"
docker ps --format '{{.Names}} {{.Status}}' | Select-String 'open-webui'    # Up (healthy)
```

✅ **Passes when** `ssh` fails and `open-webui` is up.
🧯 **If Open WebUI is down too,** or this is a new PC, stop. This is the wrong runbook: go to `START-HERE.md`.

**2. Get the repo** at `E:\recovery`, on `main`:

```powershell
if (Test-Path 'E:\recovery\.git') { git -C E:\recovery switch main; git -C E:\recovery pull --ff-only }
else { git clone https://github.com/myceliam/ollama-cria.git E:\recovery }
```

**3. Load the helpers.** Paste this whole block once per PowerShell session:

```powershell
# V0 helpers
$repo = 'E:\recovery'
$work = 'E:\recovery-state\vps-rebuild'

function Get-WorkFile([string]$Name) {
    # A file in the work folder, through the repo's path guard (AGENTS.md).
    $p = Join-Path $work $Name
    if (-not (& (Join-Path $repo 'tools/Test-RecoveryPath.ps1') -Path $p -Root 'E:\recovery-state')) { throw "STOP: $p fails the path check" }
    return $p
}

$null = Get-WorkFile 'PROGRESS.md'
New-Item -ItemType Directory -Path $work -Force | Out-Null
Import-Module (Join-Path $repo 'tools/RecoveryHost.psm1'), (Join-Path $repo 'tools/RecoveryVps.psm1'), (Join-Path $repo 'tools/StackCapture.psm1') -Force
$machine = New-RecoveryHost

function Invoke-Vps {
    # Runs one of the repo's VPS scripts on the VPS as root, as the controller
    # does. Prints its lines (never a public address) and returns its exit
    # code and FACT values.
    param([string]$Script, [string[]]$Arguments = @(), [string[]]$InputLines = @())
    $path = if ([IO.Path]::IsPathRooted($Script)) { $Script } else { Join-Path $repo "linux/stages/$Script" }
    $r = Invoke-VpsScript -Machine $machine -Alias vps -Path $path -Arguments $Arguments -InputLines $InputLines
    $facts = @{}
    foreach ($l in $r.Output) { if ($l -match '^FACT (\S+) ?(.*)$') { $facts[$Matches[1]] = $Matches[2] } }
    $r.Output | Where-Object { $_ -notmatch '^FACT public_ipv' } | ForEach-Object { Write-Host $_ }
    Write-Host "exit code: $($r.ExitCode)"
    [pscustomobject]@{ ExitCode = $r.ExitCode; Facts = $facts }
}

function Invoke-VpsBash {
    # A short bash script from this runbook, run the same way. Arguments
    # arrive as $1, $2 and so on: pass addresses that way, never in the text.
    param([string]$Text, [string[]]$Arguments = @())
    $f = Get-WorkFile 'snippet.sh'
    [IO.File]::WriteAllText($f, ($Text -replace "`r", ''))
    Invoke-Vps $f $Arguments
}

function Start-VpsLong {
    # Invoke-Vps for a step that outlasts one tool call. It runs in its own
    # minimised window and writes $work\<Name>.log, whose last line is
    # 'exit code: N' when it has finished. Arguments travel in the
    # environment, so no address lands in a file.
    param([string]$Name, [string]$Script, [string[]]$Arguments = @(), [string[]]$InputLines = @())
    $log = Get-WorkFile "$Name.log"
    $in = Get-WorkFile "$Name.input"
    $runner = Get-WorkFile "$Name.ps1"
    [IO.File]::WriteAllLines($in, [string[]]$InputLines)
    [IO.File]::WriteAllLines($runner, [string[]]@(
            "Import-Module '$(Join-Path $repo 'tools/RecoveryHost.psm1')', '$(Join-Path $repo 'tools/RecoveryVps.psm1')'"
            "`$arguments = @(`$env:CRIA_VPS_ARGS -split ' ' | Where-Object { `$_ })"
            "`$r = Invoke-VpsScript -Machine (New-RecoveryHost) -Alias vps -Path '$(Join-Path $repo "linux/stages/$Script")' -Arguments `$arguments -InputLines @(Get-Content -LiteralPath '$in')"
            "`$r.Output | Where-Object { `$_ -notmatch '^FACT public_ipv' } | Set-Content -LiteralPath '$log'"
            "Add-Content -LiteralPath '$log' `"exit code: `$(`$r.ExitCode)`""))
    Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
    $env:CRIA_VPS_ARGS = $Arguments -join ' '
    try { Start-Process -FilePath pwsh -ArgumentList '-NoProfile', '-File', $runner -WindowStyle Minimized }
    finally { Remove-Item Env:CRIA_VPS_ARGS -ErrorAction SilentlyContinue }
    "started $Name; read $log until its last line is 'exit code: N'"
}

function Set-StepDone([string]$Step) {
    # Ticks the step in Liam's progress copy.
    $p = Get-WorkFile 'PROGRESS.md'
    $t = [IO.File]::ReadAllText($p) -replace "(?m)^\| $Step \| ⬜ \|", "| $Step | ✅ $(Get-Date -Format 'd MMM HH:mm') |"
    [IO.File]::WriteAllText($p, $t)
}

if (-not (Test-Path (Get-WorkFile 'PROGRESS.md'))) { Copy-Item (Join-Path $repo 'docs/VPS-REBUILD-HUMAN.md') (Get-WorkFile 'PROGRESS.md') }
```

Tell Liam that `E:\recovery-state\vps-rebuild\PROGRESS.md` shows where the rebuild is up to.

**4. 👤 The one question.** It decides V8.

> 💬 "Your VPS is down and your PC is fine, so I'll rebuild only the VPS (step V0 of VPS-REBUILD). One question first. Did the old server just die (a provider fault, deleted, a broken update), or might someone have got into it?
> 1. **It just died:** I reuse your saved keys from Bitwarden. Quickest.
> 2. **It might have been hacked, or you're not sure:** you make new Mullvad and Brave keys, and at the end I list the other keys to change."

Remember the answer: 1 is path **8A**, 2 is path **8B**. Then `Set-StepDone V0`.

---

## V1 · A new server 👤

> 💬 "Your turn (V1), in the IONOS control panel:
> 1. If the old server still runs and might have been hacked, power it off. Don't delete it yet.
> 2. Rebuild it, or order a new VPS, with **Ubuntu 24.04 LTS**, in the UK. The same size as before is safest (it needs at least 8 GB of RAM).
> 3. Open its remote console and log in as **root**. The panel shows the root password.
>
> Tell me when you see a prompt like `root@...:~#`."

✅ **Passes when** Liam has a root prompt.
🧯 **Ubuntu 24.04 is not offered:** take the nearest 24.04 image the provider has. Not 26.04: the stack is only proven on 24.04 (RESTORE.md, Prerequisites).

---

## V2 · Write the bootstrap script 🤖

It fills in `linux/stages/02-bootstrap.sh` with the account `liam`, the node name `vps` and the PC's **public** key (not a secret).

```powershell
# V2 bootstrap
$pubFile = ssh -G vps | Where-Object { $_ -like 'identityfile *' } |
    ForEach-Object { ($_.Substring(13) -replace '^~', $HOME) + '.pub' } |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $pubFile) { throw "no .pub file beside the key 'ssh -G vps' names" }
$pub = (Get-Content -LiteralPath $pubFile -TotalCount 1).Trim()
$text = ([IO.File]::ReadAllText((Join-Path $repo 'linux/stages/02-bootstrap.sh')) -replace "`r", '').
    Replace('{{USER}}', 'liam').Replace('{{NODE}}', 'vps').Replace('{{PUBLIC_KEY}}', $pub)
$bootstrap = Get-WorkFile 'vps-bootstrap.sh'
[IO.File]::WriteAllText($bootstrap, $text)
notepad $bootstrap
```

✅ **Passes when** Notepad shows the script, with no `{{` left in it. `Set-StepDone V2`.

---

## V3 · Run the bootstrap 👤

> 💬 "Your turn (V3). I've opened `vps-bootstrap.sh` in Notepad. Press Ctrl+A, then Ctrl+C. Paste it into the server's root console and press Enter. It takes a minute or two.
> At the end it prints a line containing `SHA256:`. Please send me that line. It's the server's fingerprint, which is public, not a secret. Don't run the `tailscale up` line yet; that's the next step."

✅ **Passes when** you have `SHA256:` followed by 43 characters. Keep it as `$fp`:

```powershell
$fp = 'SHA256:<the 43 characters Liam sent>'
```

🧯 **When it fails:**
- **The console won't paste** (some web consoles can't): Liam opens his own PowerShell window and runs `ssh root@<the server's public address from the panel>`, types the root password, and pastes there. That login stops working at V6, when SSH moves to the tailnet.
- **`apt-get` says the lock is held:** Ubuntu is updating itself on first boot. Wait two minutes and paste again. The script is safe to run twice.
- **The fingerprint line is missing:** ask Liam to run `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` in the console and send that line.

`Set-StepDone V3`.

---

## V4 · Tailscale: the same name, the same address 👤

Keeping the old tailnet **address** means nothing on the PC or in Open WebUI changes. Keeping the **name** means `ssh vps` and the relay still find it.

> 💬 "Your turn (V4), in the Tailscale admin console, on the Machines page:
> 1. Find the old **vps** machine and copy its 100.x.x.x address into Notepad. Your PC's stack expects that address.
> 2. Open its ⋯ menu and choose **Remove**.
> 3. In the server's console, run `tailscale up --hostname=vps`, open the link it prints, and connect the machine.
> 4. Back on the Machines page, check the new machine is called exactly **vps**, with no `-1`. If not, use ⋯ → **Edit machine name**.
> 5. ⋯ → **Edit machine IPv4**, and enter the old address from step 1.
> 6. ⋯ → **Disable key expiry**.
> 7. If the old machine had tags, give the new one the same tags (⋯ → **Edit ACL tags**).
>
> Tell me when that's done, and whether step 5 worked."

Then check, keeping the addresses in memory:

```powershell
# V4 check
tailscale ping -c 3 vps
$ep = Get-TailnetEndpoint -SshHost vps
$vpsIp = $ep['VPS_TS_IP']; $pcIp = $ep['PC_TS_IP']
$kept = (Find-TailnetAddress -Text ([IO.File]::ReadAllText('E:\ai\ollama\docker-compose.yml'))) -contains $vpsIp
"the new VPS has the address the PC's stack expects: $kept"
```

✅ **Passes when** `tailscale ping` gets replies and `$kept` is `True`.
🧯 **When it fails:**
- **"expected one node named 'vps' ... found 2":** the old machine is still there, or the new one is `vps-1`. Steps 2 and 4.
- **"... found 0":** the new machine is not connected yet, or has another name. Step 3 again.
- **`$kept` is `False`:** Edit IPv4 didn't take, or the menu had no such entry. Ask Liam to try step 5 once more. If it can't be done, carry on: V12B updates the PC side instead.
- **Liam lost the old address:** the PC's stack still names it: `Select-String -Path E:\ai\ollama\docker-compose.yml -Pattern 'VPS_HOST'`. Show him that line in the chat only.

`Set-StepDone V4`.

---

## V5 · Trust the new server's key 🤖

Only a key whose fingerprint matches the one from the console gets into `known_hosts`. The old server's keys go; the old file is kept beside it.

```powershell
# V5 trust
$config = Get-SshHostConfig -Machine $machine -Alias vps
$scan = @(& ssh-keyscan -p $config.Port $config.HostName 2>$null)
$match = @(Read-ScannedHostKey -Line $scan | Where-Object Fingerprint -CEQ $fp)
if (-not $match) { throw 'STOP: no key this server offers has the fingerprint from the console. Do not trust it.' }
$backup = "$($config.KnownHosts).cria-$(Get-Date -Format 'yyyyMMddTHHmmss')"
Update-KnownHostFile -Path $config.KnownHosts -Token (Get-KnownHostToken -Config $config) -Key $match -BackupPath $backup
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes vps true; "ssh exit code: $LASTEXITCODE"
```

✅ **Passes when** it reports the keys it removed and added, and `ssh` exits with 0.
🧯 **When it fails:**
- **STOP, no matching key:** ask Liam to read the fingerprint again (V3, last bullet). If it still differs, something else answers on that name. Don't go on; tell Liam.
- **`Permission denied (publickey)`:** the bootstrap didn't install the PC's key. Run V2 and V3 again.
- **A timeout:** `tailscale ping vps` must answer first (V4). If it does and SSH still times out, check the tailnet's access rules let the PC reach the VPS on port 22.

`Set-StepDone V5`.

---

## V6 · Base system 🤖

`02-base.sh` sets the server up as the live VPS was read on 7 October 2026: Docker and Compose at pinned versions, nftables, nginx, ufw, unattended upgrades, `ip_nonlocal_bind`, and sshd on the tailnet address only. It also tells `systemd-networkd` to keep the guard's routing rules when it restarts, a setting added on 10 October 2026 after the live VPS lost them. It installs packages, so run it in its own window:

```powershell
Start-VpsLong v6 02-base.sh run, liam, $vpsIp
```

When `v6.log` ends with `exit code: 0`, check it:

```powershell
$r = Invoke-Vps 02-base.sh check, liam, $vpsIp
```

✅ **Passes when** the check exits 0 and its facts read:

| FACT | Expected |
|---|---|
| `tailscale-ip` | `match` |
| `docker`, `compose` | version numbers, not `none` |
| `missing` | no such line |
| `nonlocal-bind` | `1` |
| `networkd-keeps-rules` | `yes` |
| `ufw`, `ufw-defaults`, `ufw-tailscale0`, `ufw-41641` | `active`, `yes`, `yes`, `yes` |
| `ufw-other-allow` | `0` |
| `ssh-listen`, `ssh-password-off`, `ssh-root-off` | `tailnet-only`, `yes`, `yes` |

🧯 **When it fails:** the `FAIL` line says why, and the full apt output is in `/var/log/ollama-cria/stage-02.log` on the VPS (`ssh vps 'sudo -n tail -n 40 /var/log/ollama-cria/stage-02.log'`). The script is safe to run again. **`tailscale-ip` not matching** means the server's tailnet address isn't the one the PC sees: sort out V4 first, because sshd moves to that address.

`Set-StepDone V6`.

---

## V7 · Put the VPS files in place 🤖

Every VPS file in `manifests/stack-files.json`, with the tailnet addresses filled in (Stage 4a's renderer), plus the guard's unit in `/etc/systemd/system/` and the restore-only files from `linux/files/web-egress/`. `05-place.sh` writes them with their owner and mode, checks each SHA-256, and never overwrites a file it didn't write.

```powershell
# V7 place
$ep = Get-TailnetEndpoint -SshHost vps
$utf8 = [Text.UTF8Encoding]::new($false)
$templated = @((Get-Content (Join-Path $repo 'manifests/endpoints.json') -Raw | ConvertFrom-Json).files.file)
$egress = '/home/liam/owui-web-egress'
$files = [Collections.Generic.List[object]]::new()
foreach ($s in (Get-Content (Join-Path $repo 'manifests/stack-files.json') -Raw | ConvertFrom-Json).sources | Where-Object host -EQ 'vps') {
    foreach ($f in $s.files) {
        $rel = "$($s.repoFolder)/$f"
        $bytes = [IO.File]::ReadAllBytes((Join-Path $repo $rel))
        if ($templated -contains $rel) { $bytes = $utf8.GetBytes((ConvertFrom-StackTemplate -Text $utf8.GetString($bytes) -Endpoint $ep)) }
        $files.Add(@{ Remote = "$($s.root.TrimEnd('/'))/$f"; Bytes = $bytes })
        if ($f -eq 'owui-web-egress-guard.service') { $files.Add(@{ Remote = "/etc/systemd/system/$f"; Bytes = $bytes }) }
    }
}
$extra = Join-Path $repo 'linux/files/web-egress'
foreach ($x in Get-ChildItem -LiteralPath $extra -Recurse -File) {
    $files.Add(@{ Remote = "$egress/" + ([IO.Path]::GetRelativePath($extra, $x.FullName) -replace '\\', '/'); Bytes = [IO.File]::ReadAllBytes($x.FullName) })
}
$placeLines = foreach ($f in $files) {
    $inHome = $f.Remote.StartsWith('/home/liam/')
    $mode = if ($inHome -and $f.Remote.EndsWith('.sh')) { '0755' } else { '0644' }
    $owner = if ($inHome) { 'liam' } else { 'root' }
    $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($f.Bytes)).ToLowerInvariant()
    "$([Convert]::ToBase64String($utf8.GetBytes($f.Remote))) $mode $owner $sha $([Convert]::ToBase64String($f.Bytes))"
}
"$($files.Count) files to place"
$r = Invoke-Vps 05-place.sh liam -InputLines $placeLines
```

✅ **Passes when** it exits 0 and every line reads `PLACED new` (or `same` on a second run), one per file.
🧯 **When it fails:**
- **`{{X}} has no value`:** that node isn't in the tailnet under its old name. Back to V4.
- **`a different file is already there`:** something else wrote that file on the new server. Look at it with Liam; move it away only if you both agree, then run V7 again.

`Set-StepDone V7`.

---

## V8 · The keys 👤🤖

Take the path from V0: **8A** reuses the saved keys, **8B** makes new ones. Both end with the same shape check.

### 8A · Saved keys from Bitwarden

First make sure the staging folder exists and only Liam's account can open it:

```powershell
$s = 'E:\recovery-secrets'
if (-not (Test-Path $s)) { New-Item -ItemType Directory -Path $s | Out-Null; icacls $s /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" | Out-Null }
(Get-Acl $s).Access | Select-Object IdentityReference, FileSystemRights   # exactly one line: Liam
```

> 💬 "Your turn (V8A). In Bitwarden, open the item that holds `stack-secrets-<date>.zip`. Save the attachment **straight into `E:\recovery-secrets\`**, not Downloads. Then send me the SHA-256 from the item's notes. It's a checksum, not a secret."

Then check the bundle and place only folder 05, the egress `.env`:

```powershell
$zip = (Get-ChildItem 'E:\recovery-secrets' -Filter 'stack-secrets-*.zip' | Sort-Object LastWriteTime | Select-Object -Last 1).FullName
$sha = '<the SHA-256 Liam sent>'
& (Join-Path $repo 'tools/Restore-StackSecrets.ps1') -ZipPath $zip -Sha256 $sha -Folder 05            # checks and plans
& (Join-Path $repo 'tools/Restore-StackSecrets.ps1') -ZipPath $zip -Sha256 $sha -Folder 05 -Execute   # places it
```

✅ **Passes when** the egress row reads placed, and the shape check below passes.
🧯 **When it fails:**
- **The hash doesn't match:** the download is incomplete or it's another file. Ask Liam to save it again.
- **The map doesn't match `manifests/secrets.json`:** this is the older key safety copy, not the full bundle (START-HERE section 2). Unpack it as START-HERE 4.2 step 5 shows, then copy the one file across:
  ```powershell
  scp 'E:\recovery-secrets\bundle\05\vps-egress\.env' vps:/home/liam/owui-web-egress/.env
  ssh vps 'chmod 600 /home/liam/owui-web-egress/.env'
  ```

### 8B · New keys

**Changing keys on a VPS that already has them** (for example after a full rebuild, from `FULL-REBUILD-HUMAN.md`): first load V0's helpers (step 3) and run the `# V4 check` block, which sets `$vpsIp`. Skip the template below, because it never touches a file that exists. Liam replaces the six values in the existing file in part 3, and `SEARXNG_SECRET` stays. Then carry on with the shape check, V9, V10 (it recreates the VPN container on the new keys), V11, V12 and V13.

**🤖 First, the empty file.** It holds the seven names, and a new `SEARXNG_SECRET` made on the VPS, which nobody sees:

```powershell
# V8B template
Invoke-VpsBash @'
set -eu
f=${CRIA_ROOT:-}/home/liam/owui-web-egress/.env   # CRIA_ROOT: tests only
if [ -e "$f" ]; then echo "FAIL $f is already there; left as it is"; exit 1; fi
umask 077
{
  echo '# Filled in by Liam: the first five from the Mullvad file, BRAVE_API_KEY from the Brave dashboard.'
  echo 'VPN_ENDPOINT_IP='
  echo 'VPN_ENDPOINT_PORT='
  echo 'WIREGUARD_PUBLIC_KEY='
  echo 'WIREGUARD_PRIVATE_KEY='
  echo 'WIREGUARD_ADDRESSES='
  echo 'BRAVE_API_KEY='
  printf 'SEARXNG_SECRET=%s\n' "$(openssl rand -hex 32)"
} > "$f"
chown liam:liam "$f"
chmod 600 "$f"
echo "STEP $f written: seven names, mode 600, owner liam"
'@
```

**👤 Mullvad.**

> 💬 "Your turn (V8B, part 1 of 3: Mullvad).
> 1. Log in at mullvad.net with your account number (it's in Bitwarden).
> 2. Open your account's **Devices** list. If the old VPS's device is there, remove it.
> 3. Open the WireGuard configuration generator: https://mullvad.net/account/wireguard-config?platform=linux
> 4. **Generate a key.** That makes a new device.
> 5. Location: **Switzerland → Zurich → ch-zrh-wg-003**. This is the exit.
> 6. Under the advanced settings, turn on **Multihop** and pick the entry: **Sweden → Stockholm → se-sto-wg-202**. If it offers IPv4 only, choose that. Its kill switch option doesn't matter here, because the VPS has its own two.
> 7. Download the file and open it in Notepad. **Don't send it to me:** it holds your private key.
>
> If either server is no longer offered, pick another in the same city and tell me its name."

**👤 Brave.**

> 💬 "Part 2 of 3: Brave. Go to https://api-dashboard.search.brave.com/app/keys, create a new key, and copy it into Notepad too. Then revoke the old key. Nothing uses it now that the old VPS is gone."

**👤 Typing them in.**

> 💬 "Part 3 of 3: putting the keys in. Open a PowerShell window of your own (I can't see it) and run:
> `ssh vps -t nano /home/liam/owui-web-egress/.env`
> After each `=`, paste the value, with no spaces and no quotes:
>
> | Line | What goes after the `=` |
> |---|---|
> | `VPN_ENDPOINT_IP` | From `Endpoint`, the part **before** the colon |
> | `VPN_ENDPOINT_PORT` | From `Endpoint`, the number **after** the colon |
> | `WIREGUARD_PUBLIC_KEY` | `PublicKey`, in the `[Peer]` part |
> | `WIREGUARD_PRIVATE_KEY` | `PrivateKey`, in the `[Interface]` part |
> | `WIREGUARD_ADDRESSES` | From `Address`, only the first part, the one ending in `/32` |
> | `BRAVE_API_KEY` | The new Brave key |
>
> Leave `SEARXNG_SECRET` as it is. Save with Ctrl+O, then Enter, then exit with Ctrl+X. Close that window and tell me 'saved'. Then delete the Mullvad file with Shift+Delete, and close Notepad without saving."

### The shape check (8A and 8B)

It prints only `ok`, `EMPTY` or `WRONG SHAPE` and a length, never a value:

```powershell
# V8 shape
Invoke-VpsBash @'
f=${CRIA_ROOT:-}/home/liam/owui-web-egress/.env   # CRIA_ROOT: tests only
echo "STEP mode and owner: $(stat -c '%a %U' "$f")"
check() {
  v=$(sed -n "s/^$1=//p" "$f" | tail -n 1 | tr -d '\r' | sed 's/^"\(.*\)"$/\1/')
  if [ -z "$v" ]; then echo "STEP $1: EMPTY"
  elif [[ $v =~ $2 ]]; then echo "STEP $1: ok"
  else echo "STEP $1: WRONG SHAPE (${#v} characters)"; fi
}
check VPN_ENDPOINT_IP '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
check VPN_ENDPOINT_PORT '^[0-9]{1,5}$'
check WIREGUARD_PUBLIC_KEY '^[A-Za-z0-9+/]{43}=$'
check WIREGUARD_PRIVATE_KEY '^[A-Za-z0-9+/]{43}=$'
check WIREGUARD_ADDRESSES '^10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/32(,[0-9a-fA-F:]+/128)?$'
check BRAVE_API_KEY '^[^[:space:]"=]{20,}$'
check SEARXNG_SECRET '^[^[:space:]"]{16,}$'
'@
```

✅ **Passes when** it shows `600 liam` and all seven read `ok`.
🧯 **A line is `EMPTY` or `WRONG SHAPE`:** tell Liam which **name**, and ask him to open the file again (part 3) and fix that line. The usual causes are a space, quotes, or the whole `Address` line pasted. If `WIREGUARD_PUBLIC_KEY` and `WIREGUARD_PRIVATE_KEY` look swapped, they are the same shape, so V11's multihop check is what catches it.

`Set-StepDone V8`.

---

## V9 · Check the WireGuard settings against the guard 🤖

The guard lets exactly one plaintext packet stream out of the egress network: the handshake to the entry server's address and port. This compares the two without printing either:

```powershell
# V9 guard
Invoke-VpsBash @'
d=${CRIA_ROOT:-}/home/liam/owui-web-egress   # CRIA_ROOT: tests only
val() { sed -n "s/^$1=//p" "$d/.env" | tail -n 1 | tr -d '\r' | sed 's/^"\(.*\)"$/\1/'; }
ip=$(val VPN_ENDPOINT_IP); port=$(val VPN_ENDPOINT_PORT)
if grep -qF "ip daddr $ip udp dport $port counter accept" "$d/guard.nft"; then
  echo 'STEP MATCH: guard.nft lets the tunnel reach the entry server named in .env'
else
  echo 'FAIL MISMATCH: guard.nft allows another entry server or port than .env'
  exit 1
fi
'@
```

✅ **Passes when** it says `MATCH`.
🧯 **MISMATCH.** Either a value was mistyped, or the new Mullvad file uses another entry address or port (a different server, or Mullvad moved it).
1. Ask Liam to check the two `VPN_ENDPOINT` lines against the file's `Endpoint` line (part 3 of 8B).
2. If they are right, the guard must change. Ask: 💬 "Please send me just the `Endpoint` line from the Mullvad file. It's a Mullvad server's public address and port, not a secret; the repo already holds the old one."
3. In `$repo`, on a new branch, change the handshake line in `vps/web-egress/guard.nft` to that address and port, and the server names in the comment in `vps/web-egress/guard.sh` if they changed. Run `./tools/Test-NoSecrets.ps1`, commit, push, and open a pull request, so the next rebuild matches.
4. Run V7 again: it replaces `guard.nft` because it wrote it. Then run V9 again, and pass `guard-changed` in V10.

`Set-StepDone V9`.

---

## V10 · The guard first, then images and services 🤖

`05-services.sh` loads the guard and proves it (its nftables table, routing rule 5260 and IPv6 block 5265 exist, and Docker requires it) **before** any image is pulled or container created. Then it pulls every image at the digest in `manifests/images.json`, builds the hardened Jina Reader and searxng-mcp, starts `owui-web-egress` and `kokoro` with nothing else pulled, waits until they're healthy, and switches on only the Groq relay site in nginx.

```powershell
# V10 images
$builds = @{
    'vps-web-jina-reader' = @{ Folder = '/home/liam/owui-web-egress/jina-official' }
    'vps-web-searxng-mcp' = @{ Tag = 'searxng-mcp:1.6.0'; Folder = '/home/liam/owui-web-egress/searxng-mcp' }
}
$vpsImages = (Get-Content (Join-Path $repo 'manifests/images.json') -Raw | ConvertFrom-Json).vps |
    Where-Object project -In 'owui-web-egress', 'kokoro' | Sort-Object container
$imageLines = @(foreach ($i in $vpsImages) {
        $b = $builds[$i.container]
        if ($b) { "build $(if ($b.Tag) { $b.Tag } else { $i.image }) $($b.Folder)"; continue }
        $tag = if ($i.image -match '@|^sha256:') { '-' } else { $i.image }
        "pull $(@($i.repoDigests)[0]) $tag"
    }) | Select-Object -Unique
Start-VpsLong v10 05-services.sh run, liam, $vpsIp -InputLines $imageLines
```

Add `guard-changed` after `$vpsIp` only when V9 changed the guard's files on a server where the guard was already running. The Jina Reader build is the slow part; follow it with `ssh vps 'sudo -n tail -n 5 /var/log/ollama-cria/stage-05.log'`.

✅ **Passes when** `v10.log` ends with `exit code: 0`.
🧯 **When it fails:**
- **`the guard says it started, but its nftables table, routing rule 5260 or IPv6 block 5265 is missing`:** `ssh vps 'sudo -n journalctl -u owui-web-egress-guard -n 30'` shows why. No container was started, which is correct.
- **gluetun never turns healthy:** the tunnel can't connect. Check V8's shape and V9's match. Then `ssh vps 'sudo -n docker logs --tail 40 vps-web-gluetun'`: a handshake that never completes means the keys or endpoint are wrong, or the Mullvad device was removed.
- **A pull fails:** the registry may be down. Run it again later; images already pulled are kept.

`Set-StepDone V10`.

---

## V11 · Prove it: multihop, kill switches, nothing exposed 🤖

Ask first, because some of these take web search down for a few minutes:

> 💬 "The VPS is up. Next I prove it's safe (V11): the Mullvad route, both kill switches, a restart, and that nothing answers from the internet. Web search will drop out for a few minutes while I do. OK to go ahead?"

**11a · Checkpoint 5**

```powershell
$r = Invoke-Vps 05-services.sh check, liam, $vpsIp
curl.exe -fsS --max-time 20 "http://${vpsIp}:13100/health"
(Invoke-RestMethod "http://${vpsIp}:8880/v1/models").data.id
@((Invoke-RestMethod "http://${vpsIp}:18080/search?q=open+source+software&format=json").results).Count
```

| Check | Expected |
|---|---|
| `guard-enabled`, `guard-active`, `nft-table`, `ip-rule`, `docker-needs-guard` | all `yes` |
| `egress-running`, `kokoro-running` | `N/N`, every service up |
| `gluetun-health` | `healthy` |
| `exit-ip` | `differs` (the tunnel's exit is not the VPS's own address) |
| `listen-8880`, `listen-18099`, `listen-13100` | `tailnet-only` |
| `nginx-site`, `nginx-test` | `yes`, `ok` |
| `/health` | `status` ok, `brave_configured` true |
| Kokoro models | lists `kokoro` |
| SearXNG results | more than 0 |

**11b · The multihop route.** Mullvad's own checker, asked from inside the tunnel:

```powershell
# V11 multihop
Invoke-VpsBash @'
docker exec vps-web-brave-jina-gateway python -c "import json, urllib.request; d = json.load(urllib.request.urlopen('https://am.i.mullvad.net/json', timeout=20)); print('STEP Mullvad exit:', d.get('mullvad_exit_ip'), '| server:', d.get('mullvad_exit_ip_hostname'), '| country:', d.get('country'))"
'@
```

✅ **Passes when** it says `True`, a server starting `ch-zrh` (the Zurich **exit**), and Switzerland.
🧯 **A `se-sto` server** means traffic leaves at the entry, so it's single hop: `WIREGUARD_PUBLIC_KEY` holds the entry's key. Liam re-copies it from the `[Peer]` part of a fresh multihop file (8B). **`False`** should be impossible behind the guard: stop and tell Liam.

**11c · Restart, break the guard, kill switch.** In this order, each only after the one before passed. These are Stage 10c's tests (RESTORE.md).

```powershell
$before = (Invoke-Vps 10-vps.sh boot).Facts['boot_id']
Invoke-Vps 10-vps.sh reboot | Out-Null
```

Wait two minutes, then `ssh -o BatchMode=yes vps true` until it answers (up to ten minutes), then:

```powershell
$after = Invoke-Vps 10-vps.sh boot
"rebooted: $($after.Facts['boot_id'] -ne $before)"
$r = Invoke-Vps 05-services.sh check, liam, $vpsIp     # 11a's table again; give gluetun two minutes to turn healthy
Start-VpsLong guard 10-vps.sh guard-break, liam
```

When `guard.log` ends, run the kill switch:

```powershell
$test = ([IO.File]::ReadAllText((Join-Path $repo 'linux/stages/10-killswitch.py')) -replace "`r", '') -split "`n"
Start-VpsLong killswitch 10-vps.sh kill-switch -InputLines $test
```

| Test | FACT | Expected |
|---|---|---|
| Restart | `boot_id` | changed |
| | `guard_first`, `guard_active`, `docker_active` | `yes`, `yes`, `yes` |
| Guard broken on purpose | `docker_refused` | `yes`: Docker would not start without the guard |
| | `guard_active`, `guard_loaded`, `docker_active`, `gluetun_health` | `yes`, `yes`, `yes`, `healthy` afterwards |
| | `egress_running`, `kokoro_running` | `N/N` |
| Kill switch, tunnel stopped | `ks_search`, `ks_read` | anything but `ok` |
| | `ks_reader`, `ks_proxy_8888`, `ks_proxy_8889`, `ks_tcp4`, `ks_tcp6` | `blocked` |
| | `ks_searxng` | `none` |
| | `ks_dns_new_name` | `no-address` |
| | `ks_dns_plain_1`, `ks_dns_plain_2` | `no-answer` |
| | `ks_still_stopped` | `yes` (gluetun didn't restart the tunnel by itself mid-test) |
| Kill switch, afterwards | `ks_recovered` | `yes` |

🧯 **When it fails:** any kill-switch row that isn't as expected is a **leak**. Stop and tell Liam which name. Don't put the VPS back in use. If the tunnel didn't recover: `ssh vps 'sudo -n docker restart vps-web-gluetun'`, then V10 again. Every test restores itself on any exit.

**11d · Nothing answers from the internet.** This PC must not use a Tailscale exit node for this, or the probes leave from the tailnet:

```powershell
# V11 outside
if ((tailscale status --json | ConvertFrom-Json).ExitNodeStatus) { throw 'turn the exit node off for this test: tailscale set --exit-node=' }
$pub = (Invoke-Vps 10-vps.sh public-ip).Facts
$ports = @(22, 80, 443, 3000, 3001, 8000, 8080, 8443, 8880, 8888, 8889, 11434, 13000, 13055, 13100, 18080, 18099) +
    @("$($pub['tcp_ports'])" -split ',' | Where-Object { $_ -match '^[0-9]+$' } | ForEach-Object { [int]$_ }) | Sort-Object -Unique
$probe = & $machine.TcpProbe $pub['public_ipv4'] $ports 4000
$open = @($ports | Where-Object { $probe[$_] -ne 'closed' })
"probed $($ports.Count) ports on the VPS's public IPv4; open: $(if ($open) { $open -join ', ' } else { 'none' })"
```

✅ **Passes when** `open: none`. The PC's own exposure doesn't change in a VPS rebuild.

**11e · The tunnel side can't reach into the PC.** From the VPS host, the PC's open-terminal answers (the control). From inside the tunnel's network, the same request must be refused by the guard:

```powershell
# V11 inward
Invoke-VpsBash -Arguments $pcIp -Text @'
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://$1:18019/health" || true)
echo "STEP from the VPS host to the PC: HTTP $code (the control: anything but 000)"
docker exec vps-web-brave-jina-gateway python -c "
import sys, urllib.request
try:
    urllib.request.urlopen('http://' + sys.argv[1] + ':18019/health', timeout=8)
    print('STEP from inside the tunnel to the PC: ANSWERED, a leak')
except Exception as e:
    print('STEP from inside the tunnel to the PC: blocked (' + type(e).__name__ + ')')
" "$1"
'@
```

✅ **Passes when** the control shows a code other than `000` and the tunnel side says `blocked`. If the control shows `000`, open-terminal is down on the PC, so the test proves nothing: try port `3001` (Bolt) in both lines instead.

`Set-StepDone V11`.

---

## V12 · The PC side, and a test from Open WebUI 🤖👤

### 12A · The address was kept (V4 `$kept` is True)

Nothing on the PC changes. Prove the whole path through the PC's relay:

```powershell
# V12 relay
$body = @{ query = 'open webui'; count = 1 } | ConvertTo-Json
(Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:13100/search' -ContentType 'application/json' -Body $body -TimeoutSec 60).status
(Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:13100/read-url' -ContentType 'application/json' -Body (@{ url = 'https://www.iana.org/help/example-domains' } | ConvertTo-Json) -TimeoutSec 90).status
(Invoke-WebRequest -Uri 'http://127.0.0.1:8080/search?q=open+webui&format=json' -TimeoutSec 60).Content.Contains('"results"')
```

✅ **Passes when** it prints `ok`, `ok` and `True`.

### 12B · The address changed (only if V4 step 5 was impossible)

Five live files on the PC name the VPS's tailnet address (`manifests/endpoints.json`, every file with `VPS_TS_IP`), and Open WebUI's audio settings name it twice. Ask first:

> 💬 "The new VPS has a different tailnet address, so five files on your PC and two Open WebUI settings need the new one. I'd back each file up first, change only that address, and restart the stack. OK?"

1. In each file, back it up as `<file>.bak-<date>`, then replace the old VPS address with `$vpsIp` (the old one is in V4's notes):
   - `E:\ai\ollama\docker-compose.yml`
   - `E:\ai\ollama\web-vps-relay\relay.py`
   - `E:\ai\ollama\_support\scripts\scheduled\Watch-Fast.ps1`
   - `E:\ai\ollama\vps\owuihelp`
   - `E:\ai\ag-startuip\cline-dashboard\monitor.py`
2. Restart: `& E:\ai\ollama\restart-stack.ps1`, then `docker compose up -d` in `E:\ai\ag-startuip\cline-dashboard`.
3. 👤 In Open WebUI: **Admin Panel → Settings → Audio**. Change the text-to-speech (Kokoro, port `8880`) and speech-to-text (Groq relay, port `18099`) base URLs to the new address. Save.
4. Run 12A's checks.

### 12C · 👤 From Open WebUI

> 💬 "Your turn (V12). In Open WebUI, please try three things:
> 1. Ask something that needs a web search, for example 'search the web for today's UK headlines'.
> 2. Press the speaker icon under an answer.
> 3. Press the microphone and dictate a sentence.
>
> Tell me which worked."

✅ **Passes when** all three work. 🧯 Search fails: 11a and 12A. Speech fails: Kokoro on `8880` (11a). Dictation fails: the Groq relay, `ssh vps 'sudo -n nginx -t'` and its site in `sites-enabled`.

`Set-StepDone V12`.

---

## V13 · A new backup into Bitwarden 🤖👤

The bundle in Bitwarden now holds the old server's key in `known_hosts`, and with 8B, the old `.env` too. Take a new one with the same collector as the first capture:

```powershell
& (Join-Path $repo 'tools/Collect-StackSecrets.ps1') -Execute -StagingRoot 'E:\recovery-secrets' -SeedOut (Join-Path $work 'owui-seed-new')
```

It prints the new ZIP's path and SHA-256. The seed goes into the work folder, not the repo; it should match the one in the repo already.

> 💬 "Your turn (V13). The new backup is in `<ZIP path>`, and its SHA-256 is `<hash>`.
> 1. In Bitwarden, open the bundle's item. Replace the old attachment with this ZIP, and replace the SHA-256 in the notes with this one.
> 2. Then download it back from Bitwarden into `E:\recovery-secrets\roundtrip\` and tell me when it's there."

Then check the round trip:

```powershell
$a = (Get-FileHash '<ZIP path>').Hash
$b = (Get-ChildItem 'E:\recovery-secrets\roundtrip' -Filter '*.zip' | Get-FileHash).Hash
"round trip matches: $($a -eq $b)"
```

✅ **Passes when** it says `True`. `Set-StepDone V13`.

---

## V14 · Log it and tidy up 🤖

**1. Remove the plaintext**, with Liam's yes: the bundle ZIP and its unpacked folder (8A), the collector's run folder and the round-trip copy (V13). Check each with the repo's path guard first:

```powershell
# V14 tidy
$toRemove = @(Get-ChildItem 'E:\recovery-secrets' -Force | ForEach-Object FullName)
$toRemove                                     # show Liam this list, then:
foreach ($p in $toRemove) {
    $c = @(& (Join-Path $repo 'tools/Test-RecoveryPath.ps1') -Path $p -Root 'E:\recovery-secrets' -Detailed)[0]
    if ($c.IsValid) { Remove-Item -LiteralPath $p -Recurse -Force } else { "left: $p ($($c.Reason))" }
}
Remove-Item -LiteralPath (Get-WorkFile 'vps-bootstrap.sh'), (Get-WorkFile 'snippet.sh') -ErrorAction SilentlyContinue
```

`Remove-Item` skips the Recycle Bin, so nothing waits there.

**2. The ledger row.** An assistant writes every `AI-CHANGELOG.csv` row:

```powershell
& 'E:\ai\ollama\_support\scripts\maintenance\Add-AIChange.ps1' -Author 'Liam' -LoggedBy '<you>' -Model '<your model>' `
    -Request 'Rebuild the VPS after it was lost (docs/VPS-REBUILD-AI.md)' `
    -Summary 'Rebuilt the VPS: base, guard, gluetun/Mullvad multihop, SearXNG, Jina, gateway, Kokoro, Groq relay; keys <saved|new>; tailnet address <kept|changed>' `
    -Files 'VPS /home/liam; ~/.ssh/known_hosts on the PC; Bitwarden bundle' `
    -Steps 'V0 to V14 of docs/VPS-REBUILD-AI.md' -Completed 'Y' `
    -Verification 'checkpoint 5; multihop exit ch-zrh; guard break refused Docker; kill switch failed closed and recovered; nothing open from outside; OWUI search, speech and dictation; bundle round trip matched' `
    -Tier 'material' -Provenance 'verified-live'
```

**3. If the old server might have been hacked (8B),** tell Liam what else it held, so he can change those keys too:
- the **Groq API key**, which passes through the STT relay;
- the **Open WebUI backups** kept on the VPS in `~/owuibackup`. They hold OWUI's database, so change the provider keys stored in OWUI's connections (OpenAI, Anthropic and the rest) at each provider and in OWUI.

**4. 👤 The old server:** once Liam is happy, he deletes it in the IONOS panel.

**5. If V9 changed the guard,** make sure its pull request is merged.

`Set-StepDone V14`, and tell Liam it's finished, with anything that went differently from this runbook. Fix this runbook and `VPS-REBUILD-HUMAN.md` together wherever it did.
