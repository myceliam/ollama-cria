# 🆘 Start here: rebuilding after a disaster

**For:** the AI assistant (Claude, ChatGPT or Antigravity) helping Liam get his AI stack back.
**Read next:** [`AGENTS.md`](../AGENTS.md), then [`RESTORE.md`](RESTORE.md), the full guide this page points into. If Liam is already in the recovery menu (`Start-Recovery.cmd`), read [`MENU-HELP-FOR-AI.md`](MENU-HELP-FOR-AI.md) instead. If only the VPS is lost, go straight to [`VPS-REBUILD-AI.md`](VPS-REBUILD-AI.md).
**Last checked:** 10 October 2026.

This page gets you oriented in ten minutes: what survived, where it is, how to get SSH and the tailnet working again, and which path to take for the rest.

---

## 0. 🧭 Ground rules

1. **Never print, paste or log a secret value.** Work with names, paths, sizes and SHA-256 fingerprints only.
2. **Plan, show Liam the plan, then act.** Ask before anything that can't be undone: wiping a disk, rebuilding the VPS, deleting files.
3. **Secret files stay in `E:\recovery-secrets\`** (only Liam's account can open it) until each one is put in its place.
4. **Nothing from the bundle goes into this repo.** CI scans every file.
5. **Talk to Liam in short, numbered steps,** one question at a time, and say what each step is for.
6. **Keep Liam's place clear.** For a lost PC he drives the recovery menu, which ticks each step itself, and follows [`FULL-REBUILD-HUMAN.md`](FULL-REBUILD-HUMAN.md) with the same numbers (5A). For a lost VPS he follows [`VPS-REBUILD-HUMAN.md`](VPS-REBUILD-HUMAN.md): keep a copy as `PROGRESS.md` and tick each step as it passes (the VPS runbook does it in V0). Tell him in one line which step passed and what comes next.

---

## 1. 📦 What survived, and where

| What | Where | Who opens it |
|---|---|---|
| 🔐 Every key: `.env` files, Docker secrets, Google tokens, the `.ssh` folder, Hugging Face tokens, the VPS egress `.env`, ntfy accounts, Bolt keys | **Bitwarden**: an item holding `stack-secrets-<time>.zip`. The ZIP's SHA-256 is in the item's notes, and a copy of this page sits in the same item | 👤 Liam (master password and 2FA) |
| 🧰 The rebuild: scripts, config files, lists of models, apps, nodes and images, `RESTORE.md` | **GitHub** `myceliam/ollama-cria` (private), branch `main` | 👤 Liam signs in; 🤖 you clone |
| 🌐 The tailnet: the device list and access rules | **Tailscale** admin console, the same account as before | 👤 Liam |
| 💾 Open WebUI backups (database, uploads, settings) | On the PC in `D:\owuibackups\` (nightly, newest 7), and on the VPS in `~/owuibackup` (every 3 days, newest 10) | 🤖 if that machine survived |
| 📥 Model weights, Docker images, apps | Not backed up: downloaded again from the lists in `manifests\` | 🤖 |

---

## 2. 🔎 Which ZIP do you have?

Bitwarden can hold two kinds. Read the packing list inside the ZIP, `00-RESTORE-MAP.json`, without unpacking anything (it holds names and hashes, never a value):

```powershell
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead('E:\recovery-secrets\stack-secrets-<time>.zip')
try {
    $entry = $zip.Entries | Where-Object Name -eq '00-RESTORE-MAP.json' | Select-Object -First 1
    $reader = [IO.StreamReader]::new($entry.Open())
    try { $map = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
} finally { $zip.Dispose() }
$map.entries | Select-Object id, folder, destination, required | Format-Table -AutoSize
```

| The map has a row with id... | It is | Take |
|---|---|---|
| `owui-seed-secrets` (folder `03`) | **The full bundle**, made by `tools\Collect-StackSecrets.ps1` | **Path A**: the automatic rebuild (section 5A) |
| `owui-webui-db` and no `owui-seed-secrets` | **The key safety copy**, made by `Export-AllKeys.ps1` on 8 October 2026 | **Path B**: by hand (section 5B) |

If both are in Bitwarden, use the full bundle, and keep the safety copy as a spare. If the map sits one folder down inside the ZIP (Liam zipped the run folder himself), the controller can't read it: take Path B, and use that inner folder wherever this page says `bundle`. If the item's notes hold no SHA-256, ask Liam before trusting the file.

---

## 3. 🗺️ What was lost?

| Lost | Do |
|---|---|
| Only the PC | 4.1 and 4.2. The VPS still trusts the PC's SSH key, so `ssh vps` works once the key is back. On Path A the menu asks at Stage 2 whether to keep the VPS or rebuild it (5A). Liam follows [`FULL-REBUILD-HUMAN.md`](FULL-REBUILD-HUMAN.md) |
| Only the VPS | [`VPS-REBUILD-AI.md`](VPS-REBUILD-AI.md), from the surviving PC. It keeps the Mullvad multihop, both kill switches and the boot order, and guides Liam through the keys. Liam follows [`VPS-REBUILD-HUMAN.md`](VPS-REBUILD-HUMAN.md) |
| Both | 4.1, 4.2, then 4.3. Liam follows [`FULL-REBUILD-HUMAN.md`](FULL-REBUILD-HUMAN.md) |

---

## 4. 🔑 Get access back

The SSH config in the bundle (`.ssh\config`) reaches the VPS by its **tailnet name**, through the alias `vps`. Nothing in it needs to change, as long as each new machine joins the tailnet under **exactly the old name**.

### 4.1 The new PC on the tailnet 👤

1. Windows 11, signed in as the account that will own the stack, PowerShell 7, winget, and BitLocker on `E:`. This is `RESTORE.md`, Prerequisites and Steps 1a to 3: on Path A the recovery menu walks Liam through them (the README's **Start here**) and also installs a browser, Tailscale, Git, Bitwarden and the assistants.
2. In the Tailscale admin console, **remove the dead PC's node first**. Then sign in to Tailscale on the new PC.
3. Check that the new node has **exactly the old name**, with no `-1` on the end. If it has one, rename it in the console. The VPS's relay and firewall, the SSH config and Tailscale Serve all use that name.

### 4.2 The keys onto the PC 🤖

**Path A:** the menu's step 3 does steps 1 to 3 below with Liam, and Stage 1 does the rest: go to 5A.

1. Make the staging folder, owner-only from the start:
   ```powershell
   $s = 'E:\recovery-secrets'
   New-Item -ItemType Directory -Path $s -Force | Out-Null
   icacls $s /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F"
   (Get-Acl $s).Access | Select-Object IdentityReference, FileSystemRights   # exactly one line: Liam
   ```
2. 👤 Liam saves the ZIP from Bitwarden **straight into** `E:\recovery-secrets\`, never into Downloads.
3. Check it: `(Get-FileHash 'E:\recovery-secrets\stack-secrets-<time>.zip').Hash` must equal the SHA-256 in the Bitwarden notes.
4. **Path A:** stop here and go to 5A. The controller unpacks the bundle and puts the SSH key in place itself (RESTORE.md Stage 1).
5. **Path B:** unpack it beside the ZIP, after checking that no member name could land outside the folder:
   ```powershell
   $zipPath = 'E:\recovery-secrets\stack-secrets-<time>.zip'
   $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
   try { $bad = $zip.Entries.FullName | Where-Object { $_ -match '(^|[\\/])\.\.([\\/]|$)|^[\\/]|:' } } finally { $zip.Dispose() }
   if ($bad) { throw "unsafe names in the ZIP: $($bad -join ', ')" }
   Expand-Archive -LiteralPath $zipPath -DestinationPath 'E:\recovery-secrets\bundle'
   ```
   Each file sits at `<folder>\<root>\<path>`, for example `04\ssh\config`. Section 6 says where each root goes.
6. **Path B:** put the `.ssh` folder back, owner-only (Windows OpenSSH refuses a private key that others can read):
   ```powershell
   $ssh = Join-Path $env:USERPROFILE '.ssh'
   New-Item -ItemType Directory -Path $ssh -Force | Out-Null
   Copy-Item -Path 'E:\recovery-secrets\bundle\04\ssh\*' -Destination $ssh -Recurse
   icacls $ssh /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" /T
   ```
7. Check: `ssh -G vps | Select-String '^(hostname|identityfile) '` shows the VPS's tailnet name and the key. If the VPS survived, `ssh vps true` now logs in with no questions, because the restored `known_hosts` already trusts it.

### 4.3 A new VPS 👤🤖

This is `RESTORE.md` Stage 2 (2a to 2c). On Path A the controller does it and tells Liam each step. On Path B, do the same by hand:

1. 👤 In the provider's console, rebuild the server with **Ubuntu 24.04 LTS**.
2. Fill in `linux/stages/02-bootstrap.sh` from the repo: `{{USER}}` is `liam`, `{{NODE}}` is `vps`, and `{{PUBLIC_KEY}}` is the one line of the `.pub` file that matches the `identityfile` from step 4.2.7. 👤 Paste it into the provider console as root. It creates `liam` with passwordless sudo, lets the PC's key in, installs Tailscale and **prints the server's host key fingerprint**. Write the fingerprint down.
3. 👤 In the Tailscale admin console, **remove the dead VPS node first**, then run the `tailscale up --hostname=vps` line the script printed and approve the node. Check that its name is exactly the old one.
4. 🤖 On the PC, trust the new server only if its key matches the fingerprint from step 2:
   ```powershell
   $name = ((ssh -G vps | Select-String '^hostname ').ToString() -split ' ')[1]
   $keys = ssh-keyscan -t ed25519 $name 2>$null
   $keys | ssh-keygen -lf -          # must show the fingerprint written down in step 2
   ssh-keygen -R $name               # forget the old server's key (a backup is kept as known_hosts.old)
   $keys | Add-Content (Join-Path $env:USERPROFILE '.ssh\known_hosts')
   ssh vps true                      # logs in with no questions
   ```
5. Carry on with RESTORE.md Stage 2d (the base system) and Stage 5 (guard, web egress, Kokoro, the STT relay). The egress `.env` comes from bundle folder `05` and goes to `/home/liam/owui-web-egress/.env`, owned by `liam`, mode `0600`.

---

## 5. 🏗️ Rebuild the rest

### 5A. With the full bundle: the recovery menu 👤

Liam drives this himself. He does the README's **Start here** (the `E:` drive, GitHub Desktop, the repo cloned to `E:\recovery`), double-clicks `Install-PowerShell7.cmd`, then `Start-Recovery.cmd`. The menu's steps 1a to 3 get the PC ready and check the bundle; steps 4 to 14 run the controller's Stages 1 to 11 (`Invoke-StackRecovery.ps1 -Execute`), answer their `ASK` lines with him, offer restarts and explain failures. It ticks each step itself, so there is no progress file to keep.

Your part is help when he asks: read [`MENU-HELP-FOR-AI.md`](MENU-HELP-FOR-AI.md). To see where he is, changing nothing:

```powershell
pwsh -NoProfile -File E:\recovery\Start-Recovery.ps1 -Status
```

At Stage 2 the menu asks whether to keep the VPS (it must offer the host key filed in the bundle's `known_hosts`) or rebuild it (Liam types `REBUILD`). Everything the stages do and check is in `RESTORE.md`. If the menu itself can't be used, the controller still runs on its own, one stage per run, answering each `ASK` with `-Accept <id>` (`RESTORE.md`, **The controller**):

```powershell
pwsh -File E:\recovery\Invoke-StackRecovery.ps1                                   # the plan; changes nothing
pwsh -File E:\recovery\Invoke-StackRecovery.ps1 -Execute -BundleSha256 '<the SHA-256 from Bitwarden>'
```

### 5B. With only the key safety copy: by hand 🤖

The controller **refuses** this ZIP: its packing list does not match `manifests\secrets.json` (it has no OWUI seed and has the OWUI database instead). Rebuild by hand, using `RESTORE.md` and each stage's script (`windows\stages\`, `linux\stages\`) as the exact recipe, in this order:

1. **Stages 2 and 3:** the VPS base (4.3 above), then the Windows runtime: WSL, Docker Desktop, Python, Git and the apps in `manifests\windows-apps.json`.
2. **Stage 4:** copy `stack\` from the repo to `E:\ai\ollama`. Fill in every placeholder listed in `manifests\endpoints.json` with the new nodes' addresses from `tailscale status --json`. `{{STALE_TS_IP}}` and `{{VPS_PUBLIC_IP}}` never take a real address (Appendix E). Then put every file from the bundle in its place (section 6).
3. **Stage 5:** the VPS side, from `vps\` in the repo.
4. **Stage 6:** models from `manifests\ollama-models.json`, ComfyUI from `comfyui-nodes.json` and `comfyui-weights.json`.
5. **Stage 7, Open WebUI:** pull the OWUI image **at the digest in `manifests\images.json`**, so the database fits it. Put the stack `.env` in place first, because its `WEBUI_SECRET_KEY` decrypts the Valves in the database. Then, with OWUI stopped:
   ```powershell
   docker volume create owui-data
   docker run --rm -v owui-data:/data -v E:\recovery-secrets\bundle\01\owui-snapshot:/src:ro alpine cp /src/webui.db /data/webui.db
   ```
   This brings back every tool, function, model preset, setting and Valve, **and the chats**. The rebuild was designed to use the cleaner OWUI seed instead; only Path A has one.
6. **Stage 7, service state:** ntfy's `user.db` and Bolt's `server-keys.json` (bundle folder `07`) go into their Docker volumes, with the containers stopped.
7. **Stages 8 to 10:** start the stack with `start-stack.ps1`, then set up Serve and the scheduled tasks from `manifests\serve.json` and `tasks.json`. Then run the checks in `manifests\acceptance.json`.
8. **Then make a full bundle,** so the next rebuild can take Path A: run `tools\Collect-StackSecrets.ps1 -Execute` and put the ZIP in Bitwarden.

---

## 6. 📍 Where each file goes

Each file in the bundle sits at `<folder>\<root>\<path>`. It goes to `<the root's place>\<path>`:

| Root | Machine | Place | Owner and mode |
|---|---|---|---|
| `stack` | PC | `E:\ai\ollama` | Liam only |
| `dashboard` | PC | `E:\ai\ag-startuip\cline-dashboard` | Liam only |
| `ssh` | PC | `%USERPROFILE%\.ssh` | Liam only |
| `hf-cache` | PC | `%USERPROFILE%\.cache\huggingface` | Liam only |
| `vps-egress` | VPS | `/home/liam/owui-web-egress` | `liam`, `0600` |
| `ntfy-data` | PC | Docker volume `ollama_ntfy-data` | As recorded in the map row |
| `bolt-data` | PC | Docker volume `ollama_bolt-data` | As recorded in the map row |
| `owui-secrets` | PC | Not a place: the values the OWUI seed refers to. Stage 7 reads them | Path A only |
| `owui-snapshot` | PC | Not a place: the OWUI database for 5B step 5 | Path B only |

The full list, with what each root holds, is in `manifests\recovery-roots.json`.

---

## 7. ⚠️ Known gaps (8 October 2026)

- **The AI change ledger** (`AI-CHANGELOG.csv` and its protocol) is only on the PC and in its backups (R-21). If the PC is gone, start a new ledger.
- **One ComfyUI LoRA, `SDXL_3DRenderStyle`,** has no download link in `manifests\comfyui-weights.json`.
- **The `ntfy_push` function** in OWUI holds an old tailnet address that matches no device. It comes back as it was. Fix it in OWUI whenever convenient.
