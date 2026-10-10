# 🏗️ Rebuilding everything: your walkthrough

**For:** you, Liam, when **the PC is lost**, or the PC and the VPS together.
**You drive it:** the recovery menu (`Start-Recovery.cmd`) runs every command for you, one step at a time, and asks before each change. This page has the same step numbers as the menu: what each step does, where you're needed, and what to check.
**Pairs with:** [`RESTORE.md`](RESTORE.md), which says exactly what each stage does and checks. Menu step 4 is Stage 1, step 5 is Stage 2, and so on (step = stage + 3).
**If only the VPS is lost:** use [`VPS-REBUILD-HUMAN.md`](VPS-REBUILD-HUMAN.md) instead.

---

## ▶️ How to start

1. Do **Start here** at the top of the [README](../README.md): the `E:` drive, GitHub Desktop, and the repo cloned to `E:\recovery`.
2. In `E:\recovery`, double-click **`Install-PowerShell7.cmd`** (bootstrap 1 of 2). It installs PowerShell 7 with winget and tells you when it's done.
3. Double-click **`Start-Recovery.cmd`** (bootstrap 2 of 2). That's the menu. Use it in Windows Terminal if you can: the ticks show as ✅ there (the old console shows `[x]` instead).

**In the menu:**

| Type | Does |
|---|---|
| Enter | The next step (marked ▶) |
| `1a`, `1b`, `2` ... `14` | That step, even if it's done: it checks everything again and only redoes what's missing |
| `b` | Go back a step: it shows as not done and runs again next |
| `r` | Start the menu from scratch (the old record is kept) |
| `c` | Check every step again, changing nothing |
| `a` | Copy a note for an assistant (see **Stuck?** below) |
| `h` | Help |
| `q` | Quit. Progress is saved after every answer |

**Inside a step,** the menu checks each task, does what it can (always asking first), and asks you about the rest:

| Answer | Means |
|---|---|
| `y` | Yes, or done: the menu checks again |
| `n` | Not yet: it shows what to do |
| `s` | Skip. Only for optional tasks, and it asks for a reason for the log |
| `q` | Back to the menu; you carry on from here next time |

**Restarts are expected.** Windows Update, winget and Stages 3 and 10 all restart the PC. Before a restart the menu asks, saves, and sets itself to reopen once you sign in. If it doesn't reopen, double-click `Start-Recovery.cmd` again.

**Stuck?** Press `a`. The menu copies a note about where you are to the clipboard (and saves it as `E:\recovery-state\help-note.txt`). Paste it into Claude, ChatGPT or Antigravity. It tells the assistant to read [`MENU-HELP-FOR-AI.md`](MENU-HELP-FOR-AI.md), which is its guide to helping you. An assistant can also see where you are, changing nothing, with `Start-Recovery.cmd -Status`.

Each step below has:

- 🖥️ **The menu:** what it checks and does for you.
- 👤 **You:** only where you're needed.
- ✅ **You should see:** how to tell it worked.
- 🧯 **If it goes wrong:** what to check.

---

## ✅ The steps

| Step | Stage | What happens | Your part |
|---|---|---|---|
| 1a | – | GitHub Desktop, sign in, and this repo | Install GitHub Desktop, sign in, clone the repo to `E:\recovery` |
| 1b | – | Board drivers, Windows Update, your drives and Windows settings | AMD chipset and ASUS drivers; updates and restarts; `E:` (and `D:`) ready; BitLocker |
| 2 | – | Apps, the GPU driver, Tailscale and your sign-ins | Say yes to winget; sign in to Tailscale and rename the PC; sign in everywhere |
| 3 | – | The secrets bundle from Bitwarden | Save the ZIP; type its SHA-256 |
| 4 | 1 | The repo, the protected folder and your keys | Nothing, usually |
| 5 | 2 | The VPS: trusted, locked down, on the tailnet | Keep or rebuild it; if rebuilt, the IONOS console |
| 6 | 3 | Windows runtime: GPU, WSL, Docker, Python, Ollama | One admin prompt, one or two restarts |
| 7 | 4 | Settings files with the new addresses, keys in place | Nothing |
| 8 | 5 | The VPS side: the guard, VPN, search, Kokoro, dictation relay | Nothing |
| 9 | 6 | ComfyUI, every model and weight | Download tokens, if asked |
| 10 | 7 | Docker images, volumes, and Open WebUI's settings | Make the admin account; make an API key |
| 11 | 8 | The whole stack starts, Serve, scheduled tasks | One admin prompt; open OWUI on the phone |
| 12 | 9 | Proof every feature works | Try nine things in OWUI and on the phone |
| 13 | 10 | Restart, outside tests, VPS kill switch, first backup | Restart; phone test; Bitwarden |
| 14 | 11 | Plain copies of your keys deleted, rebuild recorded | Commit the new seed (an assistant helps) |

The menu's ✅ ticks are the progress record: nothing on this page needs ticking.

---

## 🔐 Your secrets: what you handle, and where they go

| Secret | Where you get it | Where it goes | Does an assistant see it? |
|---|---|---|---|
| Bitwarden master password and 2FA | Your head and your phone | Bitwarden only | ❌ No |
| The backup bundle `stack-secrets-<date>.zip` | Bitwarden | `E:\recovery-secrets\` (only your account can open it) | ❌ Only its SHA-256 |
| GitHub, Tailscale and IONOS logins | Bitwarden | Their sign-in pages | ❌ No |
| The VPS root password (rebuild only) | The IONOS panel | The IONOS console, once | ❌ No |
| The new server's fingerprint (rebuild only) | The IONOS console | You type it into the menu | ✅ Yes: it's public, not a secret |
| Hugging Face and Civitai tokens | Bitwarden | A one-line file the menu names | ❌ No |
| Your new Open WebUI admin password | You choose it | Open WebUI, and Bitwarden | ❌ No |
| The new Open WebUI API key | Open WebUI | A file the menu names | ❌ No, it goes straight into place |
| Mullvad, Brave, Groq, OpenAI, Anthropic and the rest | Inside the bundle | Put in place by the stages | ❌ No |

The menu never shows or logs what you type for a secret, and the SHA-256 you type is a fingerprint, not a secret. The Mullvad WireGuard key, the multihop servers and the Brave key come back from the bundle unchanged. If you think the old machines were **hacked**, finish this rebuild first. Then follow [`VPS-REBUILD-HUMAN.md`](VPS-REBUILD-HUMAN.md) from V8B to V13 with an assistant to make new Mullvad and Brave keys and back them up, and change the other provider keys at their websites.

---

## The steps in detail

### Step 1a · GitHub Desktop, sign in, and this repo

👤 **You,** before the menu exists (the README's **Start here** says the same):
1. In Edge, download **GitHub Desktop** from desktop.github.com and install it.
2. Sign in to GitHub (from Bitwarden).
3. **File → Clone repository → `myceliam/ollama-cria`**, with the local path **`E:\recovery`**.

🖥️ **The menu** checks GitHub Desktop is installed, that `E:\recovery` is a clone of `myceliam/ollama-cria` on `main` with no local changes, and shows how to update it: **Fetch origin, then Pull** in GitHub Desktop, or `git -C "E:\recovery" pull --ff-only` once Git is installed in step 2.

✅ **You should see** step 1a ✅.
🧯 **If it goes wrong:**
- **It cloned into `Documents\GitHub`:** clone it again into `E:\recovery`, and start the menu from there.
- **"Local changes":** in GitHub Desktop, **Changes → right-click → Discard all changes**.
- **Don't pull in the middle of the rebuild.** Stage 1 records the repo's commit, and every later stage stops if it changes. If you must, run step 4 again afterwards.

### Step 1b · Windows Update, your drives and Windows settings

🖥️ **The menu** checks Windows 11, then starts with **your motherboard's drivers**, before Windows Update can put its generic ones on: it checks AMD's chipset driver is installed and opens AMD's page for your chipset in Edge, then opens your board's ASUS download page, and offers to stop Windows Update installing drivers at all. Then it opens Windows Update and counts what's left, offers each restart, and checks PowerShell 7.4+, winget, every drive the stack uses, BitLocker and free space on `E:`, that nothing from before is in the stack's folders, virtualisation in the firmware, file extensions shown in Explorer, and that the PC never sleeps on mains power. It fixes what it can, asking first: it turns on file extensions, sets sleep to never, and renames old stack folders to `<name>-before-rebuild-<date>`.

👤 **You:**
1. **Board drivers,** from the pages the menu opens in Edge: the **AMD chipset driver first, from AMD** (it's newer than the copy on ASUS's page), and restart. Then from ASUS's page (Driver & Tool, Windows 11 64-bit): LAN, Wi-Fi, Bluetooth and audio, and one restart at the end. Skip ASUS's chipset and graphics drivers (the graphics driver is step 2). Armoury Crate is optional.
2. **Stop Windows Update swapping them** (optional; the menu does it with one admin prompt). The catch: Windows Update then installs no drivers at all, so you update them from ASUS and NVIDIA yourself.
3. **Windows Update** until it says you're up to date, restarting when asked. Skip its optional driver updates. The menu reopens itself after each restart.
4. **`E:`**, which depends on what happened to it:
   - **A new or wiped drive:** Win+X → **Disk Management**. Initialise the disk (GPT), then **New Simple Volume**, letter **E**, NTFS.
   - **A drive that survived the reinstall:** it's locked. Double-click it in File Explorer and unlock it with its BitLocker recovery key (https://aka.ms/myrecoverykey).
5. **BitLocker on `E:`:** the menu opens the BitLocker page. Turn it on, keep the recovery key somewhere safe (your Microsoft account, and Bitwarden), and turn on **auto-unlock** so `E:` opens by itself after a restart.
6. **Test new drives before you choose** (optional). The menu installs CrystalDiskInfo and CrystalDiskMark. In CrystalDiskInfo every drive should say **Good**. Give each new drive a temporary volume, then run CrystalDiskMark on each and compare **SEQ1M Q8T1** (big files) and **RND4K Q1T1** (small reads). Stripe only two healthy drives with close SEQ1M numbers: big-file speed roughly doubles, small reads barely change, and losing either drive loses the lot. If one is much slower, keep them separate.
7. **`D:` (optional: the Hugging Face cache lives there).** With your two matching SSDs: **Settings → System → Storage → Advanced storage settings → Storage Spaces → Add a new storage pool**, tick both drives, then make a storage space: **Simple** (striped: both drives' space and speed, no protection) or **Two-way mirror** (half the space, survives one drive failing). Give it the letter **D** and NTFS. Storage Spaces wipes the drives it adds.

✅ **You should see** step 1b ✅.
🧯 **If it goes wrong:**
- **"Virtualisation is off":** restart into the BIOS and turn on **SVM Mode** (AMD).
- **`E:` has less than 400 GB free:** models and weights take hundreds of gigabytes. Free space, or skip with a reason if you know they'll fit.

### Step 2 · Apps, the GPU driver, Tailscale and your sign-ins

🖥️ **The menu** lists what's installed, then installs the rest with winget after one question: **Git, Tailscale, Bitwarden, Firefox, GitHub Desktop, Libre Hardware Monitor** (the ntfy PC-health watcher reads it), **Ditto, Everything, Claude, ChatGPT** (from the Microsoft Store), **Antigravity and the Antigravity IDE**. Git, Tailscale and Libre Hardware Monitor install at the versions the stack was built on; if a pinned version is gone, it offers the newest. It then checks the NVIDIA driver, turns **Windows Search indexing off** (Everything replaces it; one admin prompt), and walks you through Tailscale and your sign-ins.

Docker Desktop, Ollama and Python aren't here: Stage 3 installs them at their recorded versions, after WSL.

👤 **You:**
1. Say **yes** to the install, and **Yes** to each Windows prompt (UAC).
2. **The NVIDIA driver:** the menu opens nvidia.com. Install the driver for your graphics card and restart if it asks.
3. **Tailscale:**
   1. In the Tailscale admin console, note the old **pc**'s address, then **remove the old pc**.
   2. Sign in to Tailscale on this PC. It may come up as **pc-1**: rename it to **pc** (⋯ → **Edit machine name**).
   3. Optional: ⋯ → **Edit machine IPv4** to the old pc's address. Everything the stack renders then stays the same, which matters most if you keep the VPS.
   4. ⋯ → **Disable key expiry**.
4. **Sign in:** Bitwarden (required: step 3 downloads from it), then Firefox, Claude, ChatGPT, Antigravity and the Antigravity IDE.

✅ **You should see** step 2 ✅, with this PC shown as **pc** and the VPS online (if it survived).
🧯 **If it goes wrong:**
- **An app won't install:** the menu shows its download page. Install it by hand, then answer `y`.
- **The name stays `pc-1`:** the old pc is still in the admin console. Remove it, then rename.

### Step 3 · The secrets bundle from Bitwarden

**The menu doesn't unzip the bundle, on purpose.** Windows' own unzip would leave plain copies of every key where anything can read them. Stage 1 (step 4) unpacks it instead, after checking its SHA-256 and every name inside, into a folder only your account can open.

🖥️ **The menu** makes `E:\recovery-secrets\` so that only your account can open it, checks BitLocker, opens the folder in Explorer, hashes the ZIP once you've saved it, checks it's the full bundle (the restore map plus folder `03`), and looks for stray copies in Downloads.

👤 **You:**
1. In Bitwarden, open the item holding `stack-secrets-<date>.zip`. Save the attachment **straight into `E:\recovery-secrets\`**, not Downloads. Don't unzip it.
2. Type the SHA-256 from the item's notes when the menu asks. It checks the two match.

✅ **You should see** step 3 ✅, with the bundle's name and size.
🧯 **If it goes wrong:**
- **"An old `E:\recovery-secrets` from your old Windows account":** rename it in Explorer (add `-old`), and delete it once the rebuild is finished.
- **The SHA-256 doesn't match:** delete the ZIP and download it again. If it still doesn't match, the notes may hold an older hash: check the item's history.
- **"An unzipped copy":** delete that folder (Shift+Delete). Only the ZIP stays.
- **"The key safety copy, not the full bundle":** that's the older spare. The menu can't use it: rebuild by hand with an assistant, from [`START-HERE.md`](START-HERE.md) section 5B.

### Step 4 · Stage 1 · The repo, the protected folder and your keys

🖥️ **The menu runs Stage 1:** it records the repo's commit and checks it has no local changes, checks every list in `manifests\`, makes the stack's folders, checks the bundle's SHA-256 again, checks every name inside it, unpacks it into a new folder only your account can open, and puts your SSH key and config back.

✅ **You should see** step 4 ✅.
🧯 **If it goes wrong:**
- **BitLocker is off:** step 1b.
- **"The repo is at X, not Y":** something pulled or switched the repo. Run step 4 again.

### Step 5 · Stage 2 · The VPS: keep it or rebuild it

🖥️ **The menu asks first: keep the VPS, or rebuild it?**

- **Keep (`k`)**, if it still works. The menu checks the VPS offers the same host key as the one in your backup, shows it, and asks you to trust it. Stage 2 then checks and tops up its base.
- **Rebuild (`r`)**, only for a lost or broken VPS. It wipes the server, so the menu asks you to type `REBUILD`.

👤 **You, if you rebuild:**
1. In the IONOS panel, rebuild the VPS with **Ubuntu 24.04 LTS** (or order a new one in the UK).
2. Open its remote console and log in as **root**.
3. Open the setup script the menu names (`E:\recovery-secrets\vps-bootstrap.sh`) in Notepad, copy it all, paste it into the console and press Enter.
4. It ends with a line containing `SHA256:`. That's the server's fingerprint.
5. In the Tailscale admin console, **remove the old vps first**. Then run the `tailscale up --hostname=vps` line the script printed, open the link, and connect it. Check the name is exactly **vps**, then ⋯ → **Disable key expiry**.
6. Answer `y` in the menu and type the fingerprint. The menu checks its shape; Stage 2 then fetches the server's key and stops unless it matches.

🖥️ **Then Stage 2** puts Docker on at the recorded versions, the firewall (everything blocked except Tailscale), automatic security updates, and SSH that answers only on Tailscale.

✅ **You should see** step 5 ✅, including `tailscale ping vps`.
🧯 **If it goes wrong:**
- **Keep: "different host keys from the ones in your backup":** stop. Either the VPS was rebuilt since the backup, or something else is answering. Ask an assistant before going on.
- **Rebuild: the console won't paste:** in your own PowerShell window, run `ssh root@<the address from the IONOS panel>`, type the root password, and paste there.
- **"The lock is held":** Ubuntu is updating itself. Wait two minutes and paste again.
- **The fingerprint doesn't match:** stop. Something other than your new server answered. Read the line again from the console.
- **The name came out as `vps-1`:** rename it to `vps` in the Tailscale console, then run step 5 again.

### Step 6 · Stage 3 · Windows runtime

🖥️ **The menu runs Stage 3** in an admin window: it checks virtualisation and your graphics card, then installs WSL, Docker Desktop, Python 3.11 and 3.13 and Ollama at the recorded versions, pins Docker and Ollama so winget doesn't update them, and sets Ollama's settings (models on `E:\ollama-models`, the 45-second keep-alive and the rest).

👤 **You:**
1. Say **Yes** to the admin (UAC) prompt, as **your own** account.
2. When the menu asks, **restart the PC** and sign in. It reopens and carries on. This can happen twice: once for WSL, once for Docker Desktop.
3. If Docker Desktop opens asking you to accept its terms, accept them and wait for "Engine running".

✅ **You should see** step 6 ✅: the GPU and driver, Docker's engine, Ollama's settings.
🧯 **If it goes wrong:**
- **"Virtualisation is off":** restart into the BIOS and turn on **SVM Mode**.
- **"No NVIDIA driver answers":** install the driver version the report names from nvidia.com.

### Step 7 · Stage 4 · Settings files and keys

🖥️ **The menu runs Stage 4:** it writes every settings file of the stack from the repo, with the new Tailscale addresses filled in, then puts each key from your bundle in its place: on the PC, readable only by you; on the VPS, readable only by `liam`. That includes the VPN's key file with your Mullvad multihop settings and Brave key. It then checks no secret leaked into its own notes.

✅ **You should see** step 7 ✅, and the VPS's key file reported as `600 liam`.
🧯 **"A different file is already there":** a file from before is where the stage wants to write. It never overwrites what it didn't make: rename that file (add `.old`) and run step 7 again.

### Step 8 · Stage 5 · The VPS side

🖥️ **The menu runs Stage 5:** it puts the VPS's files in place, then starts the **firewall guard first** and proves it's loaded and that Docker can't start without it. Only then does it download every program at its exact recorded version, build the two it makes itself, and start the VPN container, SearXNG, Jina, the Brave/Jina gateway, Kokoro and the dictation relay.

The result is the same chain as before: **your PC → Tailscale → VPS → Mullvad Stockholm → Mullvad Zurich → Brave and websites**, with two kill switches, so neither your PC nor the VPS is the address a website sees.

✅ **You should see** step 8 ✅: the guard before Docker, the VPN healthy, the VPS's internet address **different** from the tunnel's, and a test search from your PC returning results.
🧯 **If it goes wrong:**
- **A kept VPS: "a different file is already there":** a file on the VPS differs from the one the stage rendered (often an old address). Ask an assistant to compare them; then rename the VPS's file with `.old` and run step 8 again.
- **The VPN container never turns healthy:** usually Mullvad has removed the key or changed its server address. An assistant can follow `VPS-REBUILD-AI.md` V9 to check, and V8B if you need a new key.

### Step 9 · Stage 6 · Models and weights

Stage 6 doesn't need the VPS, but the menu runs the steps in order. It's by far the slowest stage: hundreds of gigabytes.

🖥️ **The menu runs Stage 6:** ComfyUI at its recorded version with its custom nodes, every Ollama model (checking each one's fingerprint), and every ComfyUI weight (checking each file's SHA-256).

👤 **You, only if the menu asks:**
- **A download token.** Some weights need your Hugging Face or Civitai login. Accept the licence on the website if it asks, then copy the token from Bitwarden into the one-line file the menu names (in `E:\recovery-secrets\download-tokens\`). It's deleted at Stage 11. Then answer `y`.
- **"A different build" of a model.** The model's name now points at a newer version than recorded. Answer `y` to keep it, or `n` to stop.
- **"Install by hand."** A few ComfyUI nodes can't be installed automatically; the report names them.

✅ **You should see** step 9 ✅: every model and required weight `verified`, and `torch` seeing the GPU.

### Step 10 · Stage 7 · Images, volumes and Open WebUI's settings

🖥️ **The menu runs Stage 7:** it builds the stack's own Docker images, downloads the rest at their recorded versions, makes the volumes, and puts back ntfy's accounts and Bolt's keys (so your phone and Bolt clients still work). Then it starts Open WebUI alone, at the recorded version.

👤 **You, twice:**
1. **The admin account.** Open `http://127.0.0.1:3000` on the PC and create the admin account. The first account is the admin. Save the password in Bitwarden. Answer `y`.
2. **The API key.** After the stage loads your tools, functions, model presets and settings, it starts Open WebUI again. Go to **Settings → Account → API keys**, create a key, and paste it into the file the menu names (`E:\recovery-secrets\owui-api-key.txt`). Save the file and answer `y`.

✅ **You should see** step 10 ✅: 15 tools, 5 functions, 33 model presets, 21 skills and 5 prompts, one account, and nothing left unfilled.
🧯 **"OWUI refused the key":** make a new key and replace the whole contents of the file.

Your chats and old uploads don't come back. That's by design: the rebuild brings back what the stack can do, not its history.

### Step 11 · Stage 8 · The stack starts

🖥️ **The menu runs Stage 8** in an admin window: it reserves ComfyUI's port and sets its firewall rule (this PC and Tailscale only), sets the pagefile, starts ComfyUI and the whole stack, and checks every service is healthy itself (your `start-stack.ps1` can say "fine" when it isn't). It reads Open WebUI's tool list, sets up Tailscale Serve (never Funnel), and imports every scheduled task.

👤 **You:**
1. Say **Yes** to the admin (UAC) prompt, as **your own** account.
2. On your phone, with Tailscale on, open Open WebUI at your PC's Tailscale name. When the sign-in page opens, answer `y`.
3. **Only if asked:** turn off the firewall rules the report names in Windows Defender Firewall, or check the tool servers in Open WebUI's admin settings.

✅ **You should see** step 11 ✅: every service healthy, 12 health checks answering, 18 tool servers, 7 Serve rules.

### Step 12 · Stage 9 · Proof every feature works

🖥️ **The menu runs Stage 9:** it tests each service directly: the models list, every tool server, web search and page reading through the VPS, Kokoro, the dictation relay, both Google bridges, Bolt and the terminal. It loads each tool's and function's code, and asks every model preset to say "OK".

👤 **You,** nine checks. The menu asks about each one by name; answer `y` once it works:

| The menu asks about | What to try |
|---|---|
| `local-chat` | Chat with a local model; `ollama ps` shows it at 100% GPU |
| `cloud-chat` | One message each through an OpenAI, an Anthropic and a Cline model |
| `media` | `generate_image` makes a picture, `generate_video` a clip, `comfyui_studio` an image |
| `stt` | Press the microphone and say a sentence; the text appears |
| `tts` | Press Read aloud; you hear the `af_heart` voice |
| `ntfy` | Send one notification with `ntfy_push`; it reaches your phone |
| `filters` | A command goes to the right tool; a Mermaid diagram renders |
| `other-tools` | Use each of the other ten tools once (the report lists them) |
| `serve-pages` | The dashboard and Dozzle open from your phone |

✅ **You should see** step 12 ✅.
🧯 **A row fails:** the report names the stage that owns it. A Google bridge failing usually means it needs your consent again: the report gives you the bridge's sign-in link.

### Step 13 · Stage 10 · Restart, outside tests and the first backup

The menu runs this stage several times. Each visit carries on from where the last one stopped.

**10a · Restart.** 👤 Restart the PC when asked and sign in; the menu reopens. 🖥️ It checks the stack came back by itself, and that every scheduled task and startup item actually ran.

**10b · From outside.** 🖥️ It probes both machines from the internet, over IPv4 and IPv6. **Nothing may answer.** Turn off any Tailscale exit node on the PC first.
👤 **Your phone test:** on your home Wi-Fi with **Tailscale off**, try your PC's home-network address (the report gives it you) on four ports. **None may load.** Then answer `y`.

**10c · The VPS tests.** 👤 Answer `y` when nothing needs the VPS for a while; web search drops out during them. 🖥️ It restarts the VPS (the guard must come up before Docker), breaks the guard on purpose (Docker must refuse to start), and stops the VPN tunnel (every search, page read, proxy, direct connection and DNS lookup must fail). Then it puts everything back and checks search works.

**10d · The monthly reminder.** 🖥️ It sets up a notification for the 1st of each month to refresh your backup. 👤 When *Monthly backup check* reaches your phone, answer `y`.

**10e · The first backup.** 🖥️ It makes a new backup ZIP of the new system and gives you its path and SHA-256.
👤 **You:**
1. In Bitwarden, replace the old ZIP in the bundle's item with the new one, and the SHA-256 in its notes.
2. Download it back from Bitwarden into the `roundtrip` folder the report names, and answer `y`.

**Optional: the interruption test.** This tests the controller itself, and its own tests already cover it, so a real rebuild skips it.

**10f · The second run.** 🖥️ Last, it runs every checkpoint from 1 to 9 again. All must pass, changing nothing.

✅ **You should see** step 13 ✅.
🧯 **The kill-switch test reports a leak:** the stage stops and names it. Don't use web search until it's fixed.

### Step 14 · Stage 11 · Tidy up and record it

🖥️ **The menu runs Stage 11:** it deletes every plain copy of your keys the controller made: the old bundle and its unpacked files, the VPS setup script, the download tokens, the API key file, and the new backup's folders. It skips the Recycle Bin. Anything it didn't make itself is named, never deleted, until you've looked at it. Then it writes a record of the rebuild and scans the new Open WebUI seed for anything secret.

👤 **You, with an assistant's help:**
1. **The change log.** The report prints the row for your AI change log. That log isn't in the backup, so if the old PC is gone, the assistant starts a new one.
2. **The new seed.** The assistant copies the new seed into the repo, runs the tests, and commits it, so the next rebuild starts from today's setup.
3. **This guide.** Wherever the rebuild went differently, the assistant fixes this page and `RESTORE.md`.
4. **Old folders.** Delete `E:\recovery-secrets-old` (if step 3 had you rename one) with Shift+Delete.

✅ **You should see** every step ✅ in the menu. 🎉
