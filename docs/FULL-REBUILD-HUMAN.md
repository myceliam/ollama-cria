# 🏗️ Rebuilding everything: your walkthrough

**For:** you, Liam, when **the PC is lost**, or the PC and the VPS together.
**Pairs with:** [`RESTORE.md`](RESTORE.md), the agent's guide, which the agent runs through the controller (`Invoke-StackRecovery.ps1`). The stage numbers are the same, so when the agent says "Stage 6" or "2b", it means the same here.
**If only the VPS is lost:** use [`VPS-REBUILD-HUMAN.md`](VPS-REBUILD-HUMAN.md) instead.

> **The VPS is rebuilt too, even if it survived.** The controller only replaces files it placed itself, so it starts from a fresh server at Stage 2. Your keys come back from Bitwarden, so the VPN, Brave and everything else come back as they were.

---

## ▶️ How to start

Steps P and 0 are yours alone, because no assistant is installed yet. Once Claude runs on the new PC with access to `E:\`, say:

> "My PC is gone. Rebuild everything with `docs/START-HERE.md` from the `ollama-cria` repo, and keep my walkthrough ticked."

From then on the agent does the typing. It runs one stage at a time and stops whenever it needs you. Each stage below has:

- 🤖 **The agent:** what it's doing, in plain words.
- 👤 **You:** only where you're needed.
- ✅ **You should see:** how to tell it worked.
- 🧯 **If it goes wrong:** what to check, or what to tell the agent.

**Where are we up to?** The agent keeps a copy of this page at `E:\recovery-state\PROGRESS.md` and ticks the table below in it as each stage's checkpoint passes. Open that file any time. The controller's own record is `E:\recovery-state\state.json`, and the agent can show you its plan at any point (`Invoke-StackRecovery.ps1` with no `-Execute` changes nothing).

**How the agent answers the controller.** When a stage needs you, it stops with an `ASK` line. Some asks have an id, such as `gpu` or `tts`. Once you've done your part, the agent runs the same command again with `-Accept <id>`. You never type those commands yourself unless you want to.

---

## ✅ Progress

| Step | Done | What happens | Your part |
|---|---|---|---|
| P | ⬜ | The new PC is ready | Windows, PowerShell 7, BitLocker on `E:` |
| 0 | ⬜ | The basics: browser, Tailscale, Git, Bitwarden, assistants | Run one script; sign in everywhere |
| 1 | ⬜ | The repo, the protected folder and your keys | Save the backup ZIP; give its SHA-256 |
| 2 | ⬜ | A fresh VPS, trusted and locked down | IONOS console, paste a script, Tailscale |
| 3 | ⬜ | Windows runtime: GPU, WSL, Docker, Python, Ollama | One admin prompt, one or two restarts |
| 4 | ⬜ | Settings files with the new addresses, keys in place | Nothing |
| 5 | ⬜ | The VPS side: the guard, VPN, search, Kokoro, dictation relay | Nothing |
| 6 | ⬜ | ComfyUI, every model and weight | Download tokens, if asked |
| 7 | ⬜ | Docker images, volumes, and Open WebUI's settings | Make the admin account; make an API key |
| 8 | ⬜ | The whole stack starts, Serve, scheduled tasks | One admin prompt; open OWUI on the phone |
| 9 | ⬜ | Proof every feature works | Try nine things in OWUI and on the phone |
| 10 | ⬜ | Restart, outside tests, VPS kill switch, first backup | Restart; phone test; Bitwarden |
| 11 | ⬜ | Plain copies of your keys deleted, rebuild recorded | Commit the new seed (the agent helps) |

---

## 🔐 Your secrets: what you handle, and where they go

| Secret | Where you get it | Where it goes | Does the agent see it? |
|---|---|---|---|
| Bitwarden master password and 2FA | Your head and your phone | Bitwarden only | ❌ No |
| The backup bundle `stack-secrets-<date>.zip` | Bitwarden | `E:\recovery-secrets\` (only your account can open it) | ❌ Only its SHA-256 |
| GitHub, Tailscale and IONOS logins | Bitwarden | Their sign-in pages | ❌ No |
| The VPS root password | The IONOS panel | The IONOS console, once | ❌ No |
| The new server's fingerprint | The IONOS console | You read it out | ✅ Yes: it's public, not a secret |
| Hugging Face and Civitai tokens | Bitwarden | A one-line file the agent names | ❌ No |
| Your new Open WebUI admin password | You choose it | Open WebUI, and Bitwarden | ❌ No |
| The new Open WebUI API key | Open WebUI | A file the agent names | ❌ No, it goes straight into place |
| Mullvad, Brave, Groq, OpenAI, Anthropic and the rest | Inside the bundle | Put in place by the controller | ❌ No |

The Mullvad WireGuard key, the multihop servers and the Brave key come back from the bundle unchanged. If you think the old machines were **hacked**, finish this rebuild first. Then ask the agent to follow [`VPS-REBUILD-HUMAN.md`](VPS-REBUILD-HUMAN.md) from V8B to V13 to make new Mullvad and Brave keys and back them up, and change the other provider keys at their websites.

---

## The stages

### Stage P · The new PC is ready

👤 **You:**
1. Install **Windows 11**, sign in as the account that will own the stack, and run Windows Update until it says you're up to date.
2. Install **PowerShell 7**: open Terminal and run `winget install --id Microsoft.PowerShell --exact --source winget`.
3. Turn **BitLocker** on for the `E:` drive (it needs at least 400 GB free).
4. Check you can sign in to Bitwarden, GitHub and Tailscale in a browser, and open the IONOS panel.

✅ **You should see** `pwsh -v` print 7.4 or later, and `manage-bde -status E:` show "Protection On" (in an admin window).

### Stage 0 · The basics

👤 **You:**
1. Open `RESTORE.md` on github.com in Edge, and copy the script under **Step 0**.
2. Open **PowerShell 7 as Administrator**, paste it, and press Enter. It installs a browser, Tailscale, Git, Bitwarden, Claude, ChatGPT and Antigravity. If it asks for a restart, restart and run it again; it skips what's done.
3. In the Tailscale admin console, **remove the old PC's machine first**, then sign in to Tailscale on the new PC. Check it has exactly the old name, with no `-1`.
4. Sign in to Bitwarden, GitHub (in the browser) and Claude.
5. Give Claude access to the `E:\` drive, then say the start line from **How to start** above.

✅ **You should see** the new PC in Tailscale under its old name, and Claude answering with a plan.
🧯 **ChatGPT fails to install:** get it from the Microsoft Store app instead. Nothing else needs it.

### Stage 1 · The repo and your keys

🤖 **The agent** downloads the recovery repo to `E:\recovery`, checks every list in it, and makes `E:\recovery-secrets\`, a folder only your account can open. Once your ZIP is there, it checks the ZIP against the SHA-256 in Bitwarden, checks no file inside could land outside that folder, unpacks it, and puts your SSH key back.

👤 **You:**
1. If a GitHub sign-in window pops up, sign in. That's Git fetching the private repo.
2. In Bitwarden, open the item holding `stack-secrets-<date>.zip`. Save the attachment **straight into `E:\recovery-secrets\`**, not Downloads.
3. Send the agent the SHA-256 from the item's notes.

✅ **You should see** the agent report checkpoint 1 passed.
🧯 **If it goes wrong:**
- **The SHA-256 doesn't match:** delete the ZIP and download it again. If it still doesn't match, the notes may hold an older hash: stop and check the item's history.
- **"More than one stack-secrets ZIP":** keep only the one you mean.
- **BitLocker is off:** turn it on for `E:` and wait for encryption to finish.
- **The agent says you only have the "key safety copy":** that's the older spare. It can't use the controller, so it rebuilds by hand from `START-HERE.md` section 5B. The stage numbers and your jobs below still match.

### Stage 2 · A fresh VPS

**2a · The setup script.** 🤖 The agent writes a setup script for the new server, with your PC's public key in it, and stops.

👤 **You,** in the IONOS panel:
1. Rebuild the VPS with **Ubuntu 24.04 LTS** (or order a new one in the UK).
2. Open its remote console and log in as **root**.
3. Open the script the agent names (`E:\recovery-secrets\vps-bootstrap.sh`) in Notepad, copy it all, paste it into the console and press Enter.
4. It ends with a line containing `SHA256:`. That's the server's fingerprint. Send it to the agent.
5. In the Tailscale admin console, **remove the old vps machine first**. Then run the `tailscale up --hostname=vps` line the script printed, open the link, and connect it. Check the name is exactly **vps**, then use ⋯ → **Disable key expiry**.

**2b · Names and access.** 👤 Check in the Tailscale console that both new machines have their old names and that your access rules still let them reach each other. The agent then answers the controller with your fingerprint (`-Accept vps-bootstrap`).

**2c · Trust.** 🤖 The agent fetches the server's key and stops unless it matches your fingerprint. Only then does your PC trust it.

**2d · The base.** 🤖 Docker at the recorded versions, the firewall (everything blocked except Tailscale), automatic security updates, and SSH that answers only on Tailscale.

✅ **You should see** checkpoint 2 passed, including `tailscale ping vps`.
🧯 **If it goes wrong:**
- **The console won't paste:** in your own PowerShell window, run `ssh root@<the address from the IONOS panel>`, type the root password, and paste there.
- **"The lock is held":** Ubuntu is updating itself. Wait two minutes and paste again.
- **The fingerprint doesn't match:** stop. Something other than your new server answered. Read the line again from the console.
- **The name came out as `vps-1`:** rename it to `vps` in the Tailscale console (⋯ → Edit machine name) and tell the agent.

### Stage 3 · Windows runtime

🤖 **The agent** checks virtualisation and your graphics card, then installs WSL, Docker Desktop, Python 3.11 and 3.13 and Ollama at the recorded versions, pins Docker and Ollama so they don't update themselves through winget, and sets Ollama's settings (models on `E:\ollama-models`, the 45-second keep-alive and the rest).

👤 **You:**
1. Say **Yes** to the one admin (UAC) prompt.
2. When the agent asks, **restart the PC**, sign in, and tell it you're back. This can happen twice: once for WSL, once for Docker Desktop.
3. If Docker Desktop opens asking you to accept its terms, accept them and wait for "Engine running".

✅ **You should see** checkpoint 3 passed: the GPU and driver, Docker's engine, Ollama's settings.
🧯 **If it goes wrong:**
- **"Virtualisation is off":** restart into the BIOS and turn on **SVM** (AMD), then tell the agent.
- **"No NVIDIA driver answers":** install the driver version the agent names from nvidia.com, or let Windows Update do it.

### Stage 4 · Settings files and keys

🤖 **The agent** writes every settings file of the stack from the repo, with the new Tailscale addresses filled in, then puts each key from your bundle in its place: on the PC, readable only by you; on the VPS, readable only by `liam`. That includes the VPN's key file with your Mullvad multihop settings and Brave key. It then checks no secret leaked into its own notes.

✅ **You should see** checkpoint 4 passed, and the VPS's key file reported as `600 liam`.

### Stage 5 · The VPS side

🤖 **The agent** puts the VPS's files in place, then starts the **firewall guard first** and proves it's loaded and that Docker can't start without it. Only then does it download every program at its exact recorded version, build the two it makes itself, and start the VPN container, SearXNG, Jina, the Brave/Jina gateway, Kokoro and the dictation relay.

The result is the same chain as before: **your PC → Tailscale → VPS → Mullvad Stockholm → Mullvad Zurich → Brave and websites**, with two kill switches, so neither your PC nor the VPS is the address a website sees.

✅ **You should see** checkpoint 5 passed: the guard before Docker, the VPN healthy, the VPS's internet address **different** from the tunnel's, and a test search from your PC returning results.
🧯 **The VPN container never turns healthy:** usually Mullvad has removed the key or changed its server address. The agent can follow `VPS-REBUILD-AI.md` V9 to check, and V8B if you need a new key.

### Stage 6 · Models and weights

Stage 6 doesn't need the VPS, so the agent may run it while you're still in the IONOS console at Stage 2. It's by far the slowest stage: hundreds of gigabytes.

🤖 **The agent** downloads ComfyUI at its recorded version with its custom nodes, every Ollama model (checking each one's fingerprint), and every ComfyUI weight (checking each file's SHA-256).

👤 **You, only if asked:**
- **A download token.** Some weights need your Hugging Face or Civitai login. Accept the licence on the website if it asks, then copy the token from Bitwarden into the one-line file the agent names (in `E:\recovery-secrets\download-tokens\`). It's deleted at Stage 11.
- **"A different build" of a model.** The model's name now points at a newer version than recorded. Say keep it (`-Accept model:<name>`) or stop.
- **"Install by hand."** A few ComfyUI nodes can't be installed automatically; the agent names them.

✅ **You should see** checkpoint 6 passed: every model and required weight `verified`, and `torch` seeing the GPU.

### Stage 7 · Images, volumes and Open WebUI's settings

🤖 **The agent** builds the stack's own Docker images, downloads the rest at their recorded versions, makes the volumes, and puts back ntfy's accounts and Bolt's keys (so your phone and Bolt clients still work). Then it starts Open WebUI alone, at the recorded version.

👤 **You, twice:**
1. **The admin account.** Open `http://127.0.0.1:3000` on the PC and create the admin account. The first account is the admin. Save the password in Bitwarden.
2. **The API key.** After the agent loads your tools, functions, model presets and settings, it starts Open WebUI again. Go to **Settings → Account → API keys**, create a key, and paste it into the file the agent names (`E:\recovery-secrets\owui-api-key.txt`). Save the file and tell the agent.

✅ **You should see** checkpoint 7 passed: 15 tools, 5 functions, 33 model presets, 21 skills and 5 prompts, one account, and nothing left unfilled.
🧯 **"OWUI refused the key":** make a new key and replace the whole contents of the file.

Your chats and old uploads don't come back. That's by design: the rebuild brings back what the stack can do, not its history.

### Stage 8 · The stack starts

🤖 **The agent** reserves ComfyUI's port and sets its firewall rule (this PC and Tailscale only), sets the pagefile, starts ComfyUI and the whole stack, and checks every service is healthy itself (your `start-stack.ps1` can say "fine" when it isn't). It reads Open WebUI's tool list, sets up Tailscale Serve (never Funnel), and imports every scheduled task.

👤 **You:**
1. Say **Yes** to the admin (UAC) prompt, as **your own** account.
2. On your phone, with Tailscale on, open Open WebUI at your PC's Tailscale name. When the sign-in page opens, tell the agent (`-Accept owui-phone`).
3. **Only if asked:** turn off the firewall rules the agent names in Windows Defender Firewall, or check the tool servers in Open WebUI's admin settings (`-Accept tool-catalogue`).

✅ **You should see** checkpoint 8 passed: every service healthy, 12 health checks answering, 18 tool servers, 7 Serve rules.

### Stage 9 · Proof every feature works

🤖 **The agent** tests each service directly: the models list, every tool server, web search and page reading through the VPS, Kokoro, the dictation relay, both Google bridges, Bolt and the terminal. It loads each tool's and function's code, and asks every model preset to say "OK".

👤 **You,** nine checks. Tell the agent each one as you go:

| Answer | What to try |
|---|---|
| `local-chat` | Chat with a local model; `ollama ps` shows it at 100% GPU |
| `cloud-chat` | One message each through an OpenAI, an Anthropic and a Cline model |
| `media` | `generate_image` makes a picture, `generate_video` a clip, `comfyui_studio` an image |
| `stt` | Press the microphone and say a sentence; the text appears |
| `tts` | Press Read aloud; you hear the `af_heart` voice |
| `ntfy` | Send one notification with `ntfy_push`; it reaches your phone |
| `filters` | A command goes to the right tool; a Mermaid diagram renders |
| `other-tools` | Use each of the other ten tools once (the agent lists them) |
| `serve-pages` | The dashboard and Dozzle open from your phone |

✅ **You should see** checkpoint 9 passed.
🧯 **A row fails:** the agent names the stage that owns it. A Google bridge failing usually means it needs your consent again: the agent gives you the bridge's sign-in link.

### Stage 10 · Restart, outside tests and the first backup

The agent runs this stage several times. Each visit carries on from where the last one stopped.

**10a · Restart.** 👤 Restart the PC when asked, sign in, and tell the agent. 🤖 It checks the stack came back by itself, and that every scheduled task and startup item actually ran.

**10b · From outside.** 🤖 It probes both machines from the internet, over IPv4 and IPv6. **Nothing may answer.** Turn off any Tailscale exit node on the PC first.
👤 **Your phone test:** on your home Wi-Fi with **Tailscale off**, try your PC's home-network address (the agent gives it you) on four ports. **None may load.** Then tell the agent (`-Accept lan-closed`).

**10c · The VPS tests.** 👤 Say OK when nothing needs the VPS for a while (`-Accept vps-tests`); web search drops out during them. 🤖 It restarts the VPS (the guard must come up before Docker), breaks the guard on purpose (Docker must refuse to start), and stops the VPN tunnel (every search, page read, proxy, direct connection and DNS lookup must fail). Then it puts everything back and checks search works.

**10d · The monthly reminder.** 🤖 It sets up a notification for the 1st of each month to refresh your backup. 👤 When *Monthly backup check* reaches your phone, tell the agent (`-Accept reminder`).

**10e · The first backup.** 🤖 It makes a new backup ZIP of the new system and gives you its path and SHA-256.
👤 **You:**
1. In Bitwarden, replace the old ZIP in the bundle's item with the new one, and the SHA-256 in its notes.
2. Download it back from Bitwarden into the `roundtrip` folder the agent names, and tell it.

**Optional: the interruption test.** This tests the controller itself, and its own tests already cover it, so a real rebuild skips it. If you want it anyway: the agent runs Stage 9 and you press **Ctrl+C** while it says `running`; it runs again and must finish.

**10f · The second run.** 🤖 Last, it runs every checkpoint from 1 to 9 again. All must pass, changing nothing.

✅ **You should see** checkpoint 10 passed.
🧯 **The kill-switch test reports a leak:** the agent stops and names it. Don't use web search until it's fixed.

### Stage 11 · Tidy up and record it

🤖 **The agent** deletes every plain copy of your keys the controller made: the old bundle and its unpacked files, the VPS setup script, the download tokens, the API key file, and the new backup's folders. It skips the Recycle Bin. Anything it didn't make itself is named, never deleted, until you've looked at it. Then it writes a record of the rebuild and scans the new Open WebUI seed for anything secret.

👤 **You, with the agent's help:**
1. **The change log.** It gives the agent the row to add to your AI change log. That log isn't in the backup, so if the old PC is gone, the agent starts a new one.
2. **The new seed.** The agent copies the new seed into the repo, runs the tests, and commits it, so the next rebuild starts from today's setup.
3. **This guide.** Wherever the rebuild went differently, the agent fixes this page and `RESTORE.md`.

✅ **You should see** every row in the progress table ticked. 🎉
