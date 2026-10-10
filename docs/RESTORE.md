# 🛟 Stack Rebuild Guide

**Clean deployment of the PC (Windows 11) and VPS (Ubuntu) · Open WebUI, Ollama, ComfyUI, MCP tools and the Mullvad web egress**

> **Goal:** two brand-new machines end up with the same capabilities you have today: the same models, tools, MCP servers, functions, skills, model presets, settings, routes and automation. Chat history and old uploads are deliberately **not** restored.
> **Run it top to bottom.** Every stage says what it delivers, where it runs, and the checkpoint that must pass before the next stage starts.
> **Liam drives the rebuild with the recovery menu** (`Start-Recovery.cmd`; the README's **Start here**), which gets the PC ready in its steps 1a to 3 and then runs these stages through the controller: menu step 4 is Stage 1, up to step 14 for Stage 11. His walkthrough, [`FULL-REBUILD-HUMAN.md`](FULL-REBUILD-HUMAN.md), uses the menu's numbers. An assistant helping him reads [`MENU-HELP-FOR-AI.md`](MENU-HELP-FOR-AI.md). When only the VPS is lost, use [`VPS-REBUILD-AI.md`](VPS-REBUILD-AI.md) instead (Liam's side: [`VPS-REBUILD-HUMAN.md`](VPS-REBUILD-HUMAN.md)).

| | |
|---|---|
| **Version** | DRAFT v0.8, 10 October 2026 (v0.1 kept as `RESTORE-v0.1.md`) |
| **Author** | Claude |
| **Ledger** | AICL-0122 (plan) · AICL-0123 to AICL-0125 (round one) · AICL-0126 (v0.2) · AICL-0127, AICL-0131 (Liam's decisions) · AICL-0129, AICL-0130 (round two) · AICL-0132 (v0.3) · AICL-0147 (v0.4, Module 7) · AICL-0148 (v0.5, Module 8) · AICL-0149 (v0.6, Module 9) · AICL-0155 (v0.7, the paired guides) |
| **Verification** | Claude reviews its own work adversarially; CI runs every test on Windows and Linux (external review rounds ended on 6 October 2026) · ☐ Liam (sign-off) |
| **Status** | Built, not yet run. The capture tools, the restorer, the controller and Stages 1 to 11 exist and pass their tests (✅ in Appendix A); none has run on a new machine yet. The first real capture is done (8 October 2026). No rehearsal is planned: the guides wait for a real disaster, and each step says what should happen, how to tell it worked, and what to check when it doesn't. |

### 🔄 What changed in v0.8 (the recovery menu)

| Change | Why |
|---|---|
| **Liam drives the rebuild with one interactive menu** (`Start-Recovery.cmd`, `tools/RecoveryMenu.psm1`). It runs the commands, checks before and after each task, asks before every change, ticks each step, carries on after restarts, goes back a step or starts over, and copies a note for an assistant | Liam, 10 October 2026: a manual tool he runs himself, with checks everywhere so no step is skipped; an assistant helps only when he is stuck |
| Two launchers: `Install-PowerShell7.cmd`, then `Start-Recovery.cmd` | The menu needs PowerShell 7, which a new Windows lacks |
| Step 0 is replaced by menu steps 1a to 3: GitHub Desktop and the repo, the board's drivers before Windows Update, the chipset from AMD and the rest from ASUS (Liam: Windows' generic ones can be unstable), Windows Update and the drives, the apps through winget (with Libre Hardware Monitor, Ditto, Everything, GitHub Desktop and the Antigravity IDE added), Windows Search off, Tailscale named `pc`, the sign-ins, and the bundle saved and its SHA-256 checked | Liam's list; the checks Stage 1 would otherwise fail on come first |
| The bundle is **not** unzipped before Stage 1 | Stage 1 checks its SHA-256 and every name inside, then unpacks it into an owner-only folder; Windows' own unzip would leave plain copies where anything can read them |
| Stage 2 asks first whether to **keep** the VPS (its host key must match the one filed in the bundle's `known_hosts`) or **rebuild** it (typing `REBUILD`) | A VPS that survived need not be wiped; wiping one is never a default |
| [`MENU-HELP-FOR-AI.md`](MENU-HELP-FOR-AI.md) is the assistant's guide while the menu runs; `Start-Recovery.cmd -Status` shows where Liam is without changing anything | Help without taking over |
| The flow diagrams are tables | GitHub stopped drawing the Mermaid flowchart, though its syntax is valid |
| The optional two-VM test (`VM-TEST.md`) is gone | Liam: no modules for external testing |

### 🔄 What changed in v0.7 (the paired guides)

| Change | Why |
|---|---|
| Every rebuild has two guides with the same step numbers: this one (run by the controller) with [`FULL-REBUILD-HUMAN.md`](FULL-REBUILD-HUMAN.md), and [`VPS-REBUILD-AI.md`](VPS-REBUILD-AI.md) with [`VPS-REBUILD-HUMAN.md`](VPS-REBUILD-HUMAN.md). The assistant ticks a copy of Liam's guide as each step passes | Liam, 8 October 2026: he follows along and sees where he is needed |
| A lost VPS alone is rebuilt with `VPS-REBUILD-AI.md`, guided by an assistant from the surviving PC, with the same Mullvad multihop, both kill switches and the boot order. Liam types new keys into the VPS himself; the assistant only checks their shape | Liam chose a guided process over a one-command mode; the keys need his hands anyway |
| The interruption test in Stage 10 is optional | It tests the controller, whose own tests already prove the wipe and rerun (`tests/Invoke-StackRecovery.Tests.ps1`) |
| No rehearsal is planned; an optional test on two virtual machines was kept separate (removed in v0.8) | Liam has no spare PC or VPS |
| `tests/VpsRebuild-Runbook.Tests.ps1` parses every block of the guides, keeps the paired steps in line, and runs the VPS runbook's V0 to V10 against a fake PC and VPS | A runbook is code too |

### 🔄 What changed in v0.6 (the PC stages are built)

| Change | Why |
|---|---|
| Stage 7 builds the local images, then pulls the rest at their digests, OWUI at the seed's (7a) | C-36, C-40 |
| OWUI's volume carries a label Stage 7 checks; one it did not create is never used or removed (7b) | C-45 |
| The seed and its secrets reach the importer on standard input, never on a command line (7d) | C-39 |
| The new OWUI API key goes into the gcal bridge's `.env` only (`owui-api-consumers.json`) | The stack's code was read on 7 October 2026: nothing else calls OWUI with a key |
| Stage 8 checks every service, health URL and the tool catalogue itself, and recreates a container left on older settings (8b) | `start-stack.ps1` still exits 0 when a service is down; C-27 changes a live file and waits for Liam |
| Stage 8 imports `OWUI-Stack-Startup` and `OWUI-mcpo-Watchdog` from their live XML, not with their installers (8d) | The live watchdog runs as S4U; its installer would make it interactive |
| The ComfyUI firewall rule is the live one: TCP 8188 from the tailnet range and `127.0.0.1` (8a) | The containers reach ComfyUI from this PC through Docker Desktop, not from Docker's network |
| Stage 3 installs Python 3.13 at `C:\Python313` | The PowerShell tool's task and scripts name that path. On the live PC it is gone, so that task fails at sign-in |
| Stage 9's 🤖 rows test the services behind web search, page reading, speech, the bridges and the PowerShell tool directly, and each tool and function by loading its code | A model choosing to call a tool is not a safe, repeatable test; the 👤 rows cover the chat side |
| Stage 9 checks each preset's tools and skills against the seed and asks it one prompt, except presets built on the `comfyui_studio` pipe | That pipe makes media (a 👤 row) |
| Stage 7 run again once done places nothing twice and leaves a running stack alone | ntfy changes its `user.db` as it runs, so placing folder 07 again would be refused |
| `state.json` counts each stage's interruptions; Stage 10 reads the count for the interruption test | C-45 |
| Stage 10 is built: the PC restart with every task's sign of life, probes from outside the tailnet over IPv4 and IPv6, the VPS tests behind `-Accept vps-tests`, the monthly reminder, the first backup with its round trip, and the second run | C-20, C-21, C-43, C-45, C-47, C-51, C-52 |
| The kill-switch test asks for a word made up for each run | A cached answer would hide a leak |
| Stage 10 probes nothing while this PC uses an exit node, and only from a host with the same address family | An exit node would carry the probes through the tailnet; a missing IPv6 route would read as a closed port |
| Stage 10's seed export goes to `E:\recovery-state\owui-seed-new`, not into the repo | Changing `manifests\` before Stage 11 would stop every later stage at the release check |
| Stage 11 removes the plaintext itself and writes `rebuild-record.json`; it prints the ledger row for an assistant to add | The ledger's protocol: an assistant writes every row |

### 🔄 What changed in v0.5 (the VPS stages are built)

| Change | Why |
|---|---|
| Stage 2 writes the console bootstrap for you; it prints the new server's host key fingerprint, and you answer with `-Accept vps-bootstrap -HostKeyFingerprint SHA256:…` (2a, 2b) | The check in 2c needs a value a person saw on the console |
| The old server's keys in `known_hosts` are **replaced**, not added to; the old file is kept beside it (2c) | An old key under the same name makes ssh refuse the new server |
| The VPS base copies the live one, read on 7 October 2026: pinned Docker versions, no `sqlite3`, `ip_nonlocal_bind`, sshd on the tailnet address only, ufw open on `tailscale0` and `41641/udp` only (2d) | The rebuilt VPS should behave like today's |
| Stage 5 places files through a ledger, never over one it did not write (5a) | C-45, on the VPS |
| The guard is proved loaded and Docker proved to need it before any image or container (5b); a running guard restarts only when its files changed | C-20, C-43. Restarting the guard restarts Docker |
| Images are pulled by digest or built, then the projects start with `--pull never --wait` (5c, 5d) | Nothing unpinned reaches the VPS |
| **searxng-mcp is built** from a new Dockerfile, with a compose override pointing the service at it (5c) | R-13: the live image is a bare local ID no registry holds |
| The SearXNG search in checkpoint 5 runs automatically | One fewer manual check |
| The VPS's public address is no longer kept in the repo; files hold a placeholder | It is not needed to rebuild, and the sync now keeps it out |

### 🔄 What changed in v0.4 (the controller is built)

| Change | Why |
|---|---|
| The controller **plans by default** and runs **one stage per `-Execute`**, then stops at its checkpoint | Each checkpoint is where a person (or an assistant) reads the evidence before going on |
| Only Stages 3 and 8 run elevated, each in its own Admin window; every other stage runs as you | Files, Docker Desktop and Ollama never end up belonging to the Administrators group |
| ComfyUI, its venv and its custom nodes moved from Stage 3d to **Stage 6** | They are downloads, and Stage 6 runs as you |
| A stage that needs you stops with `ASK` lines; a question with an id is answered with `-Accept <id>` (`gpu`, `model:<name>`) and kept in `state.json` | C-48 |
| Download tokens go in `E:\recovery-secrets\download-tokens\<auth>-token.txt` (6c) | A fixed place inside the protected folder, deleted in Stage 11 |
| Ownership is proved by the file ID (Windows) or inode (Linux) | C-45. A creation time can be handed to a new file by NTFS "tunnelling" |
| A stage that passes marks what it created `keep`, so a later attempt never wipes it | C-45 |
| Stage 4 writes **the whole stack** from the repo, not only the templated files; VPS files are rendered under `E:\recovery-state\rendered\` for Stage 5 | Stage 1 no longer copies the stack |
| Installing Docker Desktop asks for a restart | Membership of `docker-users` only counts from your next sign-in |
| Exit codes: 0 done (or plan), 1 failed, 2 needs you, 3 restart and run again | Scripts and assistants can tell the outcomes apart |

### 🔄 What changed in v0.3

| Change | Why |
|---|---|
| Docker's guard drop-in is restored with the guard (Stage 5a) | C-43, live on the VPS |
| OWUI user settings travel in the seed as an allowlisted projection (Stage 7d) | C-37 |
| Every owner and member reference is remapped, not only tools and functions (Stage 7d) | C-38 |
| Local images are built **before** any container exists; OWUI's schema starts with `--no-deps` (Stage 7a, 7d) | C-36 |
| The seed exporter uses OWUI's own Valve codec, an allowlist schema and the recorded OWUI version (Stage 7d) | C-39, C-40, C-41 |
| The secrets bundle is downloaded at the end of Stage 1, so Stage 2 has the SSH key (Stage 1) | C-35 |
| One path-check helper guards every restore, fetch and clean-up (Controller, Stage 11) | C-44, C-49 |
| Interrupted stages wipe only what the controller owns and rerun (Controller) | C-45, simplified |
| A changed model digest pauses for Liam instead of failing silently (Stage 6a) | C-48, simplified |
| Stage 9 runs one acceptance row per capability (`acceptance.json`) | C-46 |
| A monthly owner checkpoint keeps the bundle and seed current (Stage 10) | C-47 |
| **Discord bridge retired** (Liam, `AICL-0131`): bridge, `discord_feed_curator` pipe, `#announcements` channel and webhook are out of scope | Owner decision |
| **`OWUI-Automation-Chat-Tidy` retired**: failing daily with 401, its automations are gone | C-51, R-20 |
| The Groq STT relay holds no secret; bundle folder 06 is removed | C-25, checked live |

---

## 📖 How to read this guide

**Where each step runs**

| Icon | Meaning |
|---|---|
| 🖥️ | PC, PowerShell 7 (`pwsh`). "Admin" means an elevated window. |
| ☁️ | VPS, **bash**, reached with `ssh vps` once Stage 2 has set it up |
| 🔐 | Needs Bitwarden |
| 👤 | A human step: Liam does it by hand |
| 🤖 | An AI step: Claude, Antigravity or ChatGPT runs or checks it |

**Status tags**

| Tag | Meaning |
|---|---|
| ✅ | Exists today at the path given |
| ♻️ | Exists today, but must be refactored before it is used (the finding ID says why) |
| 🛠️ | To build. The guide gives the manual equivalent until it exists |
| ❓ | Open item with an ID in [Appendix C](#appendix-c--register). Resolve it, never guess |

**Checkpoints.** Every stage ends with a 🛑 **Checkpoint** table. The controller runs it, prints the evidence, saves it under `E:\recovery-state\evidence\`, and stops; running the same `-Execute` command again is the "continue". A failed check stops the run; it never "warns and carries on".

---

## 🧭 What "clean deployment" means here

| Comes back (capability) | Does not come back (content) |
|---|---|
| ✅ Every Ollama model, with the same tags and the custom Modelfiles | ❌ Chats (97 today, all test data) |
| ✅ Every ComfyUI model, custom node and workflow | ❌ Uploaded files (218 rows today, few real uploads) |
| ✅ OWUI settings (the 409-row `config` table), with credentials re-injected | ❌ Notes, the single memory entry, automation run history |
| ✅ 15 tools, 5 functions, 21 skills, 33 model presets, 5 prompts | ❌ Calendar events cached in OWUI (they re-sync from Google) |
| ✅ 18 tool-server connections (16 through `mcpo-core`, plus Gmail and Calendar bridges) | ❌ Generated images and video |
| ✅ Your OWUI user settings: pinned models, tool settings, the sub-agent prompt, TTS choices | ❌ Logs and caches |
| ✅ Groups and access grants | ❌ 🗄️ Retired: Discord bridge, its pipe, channel and webhook; `OWUI-Automation-Chat-Tidy` |
| ✅ Microservices: Tika, Playwright MCP, mcpo, the gcal and Gmail bridges, ntfy, Bolt, Dozzle, open-terminal, dashboard | |
| ✅ VPS web egress through gluetun/Mullvad, the guard, Kokoro and the STT relay | |
| ✅ Tailscale Serve rules, scheduled tasks and the ComfyUI logon launcher | |

**The rule that makes this safe:** OWUI's capability state is installed from a sanitised **functional seed** kept in the recovery repo. The seed holds no secrets and no ciphertext, only references; the controller fills them from Bitwarden. A copied `webui.db` is never committed and never used as the seed.

**📌 Decisions already made by Liam:** clean deployment · repo `ollama-cria` · `OLLAMA_KEEP_ALIVE=45s` · no extra archive encryption (BitLocker plus an owner-only folder is the protection) · secrets bundle in **Bitwarden only** · Kokoro on the VPS · Discord bridge retired · build next, rather than another paper review.

---

## ✅ Prerequisites (the only manual set-up)

The menu's steps 1a to 3 check every one of these and walk Liam through what is missing.

| # | You need | How to check |
|---|---|---|
| P1 | Windows 11, fully updated, signed in as the user who will own the stack | Settings → Windows Update shows "You're up to date" |
| P2 | PowerShell 7 | `pwsh -v` prints 7.4 or later (7.6.6 today) |
| P3 | winget | `winget --version` prints a version (v1.29 today) |
| P4 | A wiped VPS running **Ubuntu 24.04 LTS**, with provider-console access | The provider console shows the server and its root login |
| P5 | 🔐 Bitwarden account, master password and 2FA | You can sign in at vault.bitwarden.com |
| P6 | GitHub account with access to the private recovery repo | You can open the repo in a browser |
| P7 | Tailscale account (the same tailnet) | You can open the admin console |
| P8 | Disk: an NVMe drive for `E:` with at least 400 GB free, BitLocker on | `manage-bde -status E:` shows "Protection On" |

> 💡 **Why Ubuntu 24.04 and not 26.04?** The live VPS runs 24.04.5 and the stack is proven there. 26.04 can be trialled later behind a clean-host test (C-33).

---

## Steps 1a to 3 · The menu gets the PC ready 👤

> **Delivers:** a PC every stage can run on: the repo, Windows up to date, `E:` with BitLocker, the apps, Tailscale under the old name, the sign-ins, and the bundle in its owner-only folder with its SHA-256 checked
> **Where:** 🖥️ the recovery menu, as Liam (not Admin)
> **Module:** ✅ `Install-PowerShell7.cmd`, `Start-Recovery.cmd`, `Start-Recovery.ps1`, `tools\RecoveryMenu.psm1`

These replace Step 0. Liam does the README's **Start here** (the `E:` drive, GitHub Desktop, the repo cloned to `E:\recovery`), double-clicks `Install-PowerShell7.cmd`, then `Start-Recovery.cmd`. The menu then checks, fixes (asking first) or walks him through each task:

| Step | Tasks (required ones in **bold**) |
|---|---|
| 1a | GitHub Desktop installed and signed in; **a clone of `myceliam/ollama-cria`**, **on `main`**, in `E:\recovery`, **no local changes**; how to update it |
| 1b | **Windows 11**; before Windows Update, the AMD chipset driver from AMD (newer than the board maker's copy), then LAN, Wi-Fi, Bluetooth and audio from the board maker (ASUS), each page opened in Edge; optionally, drivers kept out of Windows Update (`ExcludeWUDriversInQualityUpdate`); **Windows Update has nothing left**; **no restart pending**; **PowerShell 7.4+**; **winget**; new drives tested (CrystalDiskInfo, CrystalDiskMark) before choosing striped or separate; **each drive the stack uses** (`E:` required; `D:` for the Hugging Face cache); **BitLocker on `E:`**; auto-unlock; 400 GB free; **nothing from before in the stack's folders** (renamed aside, never deleted); virtualisation; file extensions shown; no sleep on mains power |
| 2 | Apps through winget, asked once: **Git**, **Tailscale**, **Bitwarden**, Firefox, GitHub Desktop, Libre Hardware Monitor, Ditto, Everything, Claude, ChatGPT (`msstore` `9PLM9XGG6VKS`), Antigravity, Antigravity IDE, at the versions in `manifests\windows-apps.json` where it pins one; the NVIDIA driver (by hand); Windows Search indexing off; **Tailscale connected** and **named `pc`** (remove the old node first, C-22); the old address and no key expiry; the VPS online; **signed in to Bitwarden**, then the other apps |
| 3 | **No old `E:\recovery-secrets` from another account**; **the folder, owner-only from birth**; **BitLocker**; **one `stack-secrets-*.zip` directly in it** (never unzipped); **its SHA-256 equal to Bitwarden's**; **the full bundle** (the restore map at the top, folder `03` inside); no stray copy in Downloads |

Docker Desktop, Ollama and Python are not installed here: Stage 3 installs them at their recorded versions, after WSL. Don't run `tailscale serve` yet; Stage 8 does that.

🛑 **Checkpoint: steps 1a to 3.** Every required task passes in the menu (✅ on steps 1a, 1b, 2 and 3). An optional task skipped needs a reason, which the log keeps. Step 4 (Stage 1) refuses to start while one of them is open, unless Liam types `SKIP` and a reason.

---

## 🗺️ The shape of it

| Menu step | Stage | Delivers | Needs |
|---|---|---|---|
| 1a to 3 | – | The PC ready, the bundle in place | – |
| 4 | 1 | Recovery release, manifests, secrets bundle | Steps 1a to 3 |
| 5 | 2 | VPS base, both hosts on the tailnet | Stage 1 |
| 6 | 3 | Windows runtime: GPU, Python, WSL, Docker, Ollama | Stage 1 |
| 7 | 4 | Endpoints rendered, secrets placed | Stages 2 and 3 |
| 8 | 5 | VPS guard, egress, Kokoro, STT relay | Stage 4 |
| 9 | 6 | Models and weights | Stages 1 and 3 |
| 10 | 7 | Images, volumes, service state, OWUI seed | Stages 5 and 6 |
| 11 | 8 | Services, Serve, automation | Stage 7 |
| 12 | 9 | Functional tests | Stage 8 |
| 13 | 10 | Reboot and rerun rehearsal, new backup | Stage 9 |
| 14 | 11 | Log and clean up | Stage 10 |

**Order rules**

- Nothing that writes data starts before Stage 7 has created its volumes and state. That stops an empty OWUI or ntfy from initialising itself in the wrong shape (C-13).
- Every local image is built before any container is created (C-36).
- The VPS is built before anything on the PC needs it (C-02).
- Stages 3 and 6 are long and independent of the VPS. The controller can run them while Liam handles VPS console steps; the menu keeps to its order.

---

## 🎛️ The controller

> **Module:** ✅ `Invoke-StackRecovery.ps1`, at the root of the recovery repo

```powershell
pwsh -File .\Invoke-StackRecovery.ps1                        # plan: every stage, its state, what the next one would do; changes nothing
pwsh -File .\Invoke-StackRecovery.ps1 -Execute               # run the next ready stage and its checkpoint, then stop
pwsh -File .\Invoke-StackRecovery.ps1 -Execute -Stage 6      # run (or run again) one stage; the stages it needs must be done
pwsh -File .\Invoke-StackRecovery.ps1 -Execute -Accept gpu   # answer a question a stage asked, by its id
pwsh -File .\Invoke-StackRecovery.ps1 -Execute -Accept vps-bootstrap -HostKeyFingerprint SHA256:<43 characters>   # Stage 2b
```

Run the same `-Execute` command again after each checkpoint, after a restart, or after doing what an `ASK` line said. Each run prints its steps, its checks and one `Result:` line.

| Behaviour | Rule |
|---|---|
| State file | `E:\recovery-state\state.json` (`controller.stateRoot` in `manifests\topology.json`). Records each stage (status, attempts, answers, data), the release commit and manifest hashes, and every item the controller created. **No secrets, ever.** Written to a temporary file and moved into place, so a crash leaves the old copy or the new one. One run at a time: `state.lock`; a lock whose process is gone is taken over. |
| Order | A stage runs once every stage it needs is done. Their checkpoints run again first; one that no longer passes stops the run. After Stage 1, nothing runs unless the repo is still at the commit and manifest hashes Stage 1 recorded. A stage that asked for a restart runs again from where it was. |
| Ownership | Every folder and file the controller creates is recorded with its identity (file ID on Windows, inode on Linux) and a rule: `wipe` or `keep`. If a stage was cut off (still marked running), only its `wipe` items are removed, only while each is still the same object, never through a link or junction; then the stage runs again. A stage that passes marks its items `keep`. It never deletes or overwrites anything it did not create (C-45). |
| Paths | One helper, 🛠️ `tools\Test-RecoveryPath.ps1`, checks every path before anything is written, copied, extracted or deleted. It must resolve inside a configured root; it rejects `..`, absolute paths in archives, links or junctions that escape, alternate data streams, device names and case-only duplicates (C-44, C-49). |
| Failure | A stage that throws or reports a problem is marked `failed`, its evidence is kept, and the run stops. A stage that needs you stops with `ASK` lines. Exit codes: 0 done (or plan), 1 failed, 2 needs you, 3 restart the PC and run the same command again. |
| Elevation | Stages 3 and 8 only. The controller starts an elevated copy of itself for that one stage (one UAC prompt); the child checks it holds the same lock and returns its exit code. Answers travel through `state.json`, never on the command line (C-14). |
| Secrets | Never in arguments, URLs, transcripts or the state file. Read from the protected staging folder only (C-14, C-05). |
| Evidence | `E:\recovery-state\evidence\stage-NN-attempt-K.json` and `.txt`: names, counts, hashes, statuses and exit codes only. After every stage that reads the bundle (1, 4, 7), each evidence file and `state.json` are matched against every value in the unpacked bundle (whole short files, `NAME=value` values, JSON strings and long lines, also as JSON escapes them). A match deletes that evidence file, keeps only the report's title and the problem, and fails the stage. A matched value is never printed (C-50). |
| VPS stages | 🛠️ `tools\RecoveryVps.psm1` sends each `linux\stages\*.sh` inside the SSH command, runs it once as root with `sudo -n` and removes it; files and image lists travel on its standard input, never as arguments. `ssh` runs with `BatchMode=yes` and `StrictHostKeyChecking=yes`. The scripts print `STEP`, `WARN`, `FACT` and `FAIL` lines, which become the stage's steps, warnings, checks and problems; they never print a file's content or an address, except Stage 10's public addresses (10b), which the controller keeps in memory and never writes down. On the VPS they leave only what they set up, their logs in `/var/log/ollama-cria/` and Stage 5's ledger. |

---

# STAGE 1 · Recovery release, manifests and the secrets bundle

> **Delivers:** the recovery repo on disk, validated manifests, the target folders, a protected staging folder, and the secrets bundle checked and unpacked inside it
> **Where:** 🖥️ PowerShell 7
> **Module:** ✅ `windows\stages\01-release.ps1`

1. Clone the repo with Git Credential Manager (browser sign-in). **Never** put a token in the URL (C-14).
   ```powershell
   git clone https://github.com/<owner>/ollama-cria.git E:\recovery
   git -C E:\recovery checkout <release-tag>
   ```
   Then start the controller (it runs Stage 1 first):
   ```powershell
   pwsh -File E:\recovery\Invoke-StackRecovery.ps1 -Execute -BundleSha256 <the SHA-256 stored with the bundle in Bitwarden>
   ```
   The repo must be a clean checkout: local changes stop the stage. No release tag is a warning; the commit is recorded either way.
2. Validate every manifest in `E:\recovery\manifests\` against the schema its `$schema` names (Appendix B lists them).
3. Create the target roots from `manifests\topology.json`:

   | Root | Holds |
   |---|---|
   | `E:\ai\ollama` | The stack: compose file, Dockerfiles, bridge source, scripts. Written from `stack\` in the repo by Stage 4. |
   | `E:\ai\ag-startuip\cline-dashboard` | Homelab dashboard source (its own compose project) |
   | `E:\ai\ollama\gmail-owui-bridge` | Gmail bridge (its own compose project) |
   | `E:\ai\comfyui\ComfyUI` | Native ComfyUI (Stage 6 clones it; not created here) |
   | `E:\ollama-models` | Ollama model store |
   | `E:\ai\generated` | OWUI generated media bind mount |
   | `E:\ai\OpenFolders\workspace`, `E:\ai\OpenFolders\mcp\intel` | open-terminal and MCP bind mounts (created empty) |

4. Create the protected staging folder `E:\recovery-secrets\` **with a restrictive ACL from birth**: owner and only grant = the current user's SID, inheritance off. Then read the ACL back and fail if anything else has access (C-04, C-05).
5. 🔐👤 **Download the bundle** (moved here from Stage 4 so Stage 2 has the SSH key, C-35). In Bitwarden, save `stack-secrets-<date>.zip` **straight into** `E:\recovery-secrets\`, never `Downloads`. The controller checks its SHA-256 against the value stored in the same Bitwarden item, checks every member path with `Test-RecoveryPath`, then extracts it in place. The ZIP, any partial download and the extracted files all stay inside the protected folder.
6. 🤖 **Place the SSH key and config now.** The private key, its `.pub` and `~\.ssh\config` (bundle folder 04) go to `%USERPROFILE%\.ssh\` with owner-only ACLs. The `vps` alias is re-pointed to the new server's name in Stage 2c.

🛑 **Checkpoint 1**

| Who | Check | Expected |
|---|---|---|
| 🤖 | `git -C E:\recovery describe --tags` | The intended release tag |
| 🤖 | Manifest validation | Every manifest passes |
| 🤖 | `(Get-Acl E:\recovery-secrets).Access` | Exactly one entry: the current user, Full Control |
| 🤖 | `manage-bde -status E:` | Protection On |
| 🤖 | Bundle SHA-256 vs the value in Bitwarden | Identical |
| 🤖 | Every bundle member passes `Test-RecoveryPath`; no file outside `E:\recovery-secrets\` | Yes |
| 🤖 | `(Get-Acl $env:USERPROFILE\.ssh\<key-name>).Access` | Current user only |

📌 **R-01:** the repo is called `ollama-cria` (Liam, 5 October 2026). The layout in Appendix D is still a proposal.

---

# STAGE 2 · VPS base and both hosts on the tailnet

> **Delivers:** a hardened Ubuntu 24.04 VPS with user `liam`, SSH key login, Docker and Tailscale; the new server's host key checked and trusted
> **Where:** ☁️ provider console first, then 🖥️ → ☁️ over SSH
> **Modules:** ✅ `windows\stages\02-vps.ps1`, `linux\stages\02-bootstrap.sh`, `linux\stages\02-base.sh`, `tools\RecoveryVps.psm1`

**Keep or rebuild.** The menu asks first. **Keep** (a VPS that survived): it reads the VPS's tailnet name and port from the restored SSH config, runs `ssh-keyscan`, and goes on only if a key the VPS offers matches one filed for it in the bundle's `known_hosts`; it then answers 2b with that fingerprint, and 2a's console steps are skipped. Stage 5 then leaves each file that is already the same, and refuses one that differs and that it did not write. **Rebuild** wipes the server, so the menu asks Liam to type `REBUILD` first.

**2a · In the provider console 👤**

The first `-Execute` of Stage 2 writes `E:\recovery-secrets\vps-bootstrap.sh` (owner-only, with the PC's **public** key from bundle folder 04 and the account filled in; removed in Stage 11) and stops with an `ASK` line. Then:

1. Rebuild the server with Ubuntu 24.04 LTS.
2. Paste `vps-bootstrap.sh` into the console as root. It creates `liam` with passwordless sudo (the scripts call `sudo -n docker …`; adding `liam` to the `docker` group would be root-equivalent), installs the public key, installs Tailscale from Tailscale's apt repository (C-15, C-53), and **prints the server's SSH host key fingerprint**. Write it down.
3. In the Tailscale admin console, **remove the old, dead VPS node first** (C-22). Then run the `tailscale up --hostname=vps` line it printed and approve the node.

**2b · Names and grants 👤**

Check in the admin console that the two new nodes have exactly the old names (no `-1` suffix) and that the tailnet access rules still let the PC and VPS reach each other on the ports in Appendix E. Then answer with the fingerprint:

```powershell
pwsh -File .\Invoke-StackRecovery.ps1 -Execute -Accept vps-bootstrap -HostKeyFingerprint SHA256:<43 characters>
```

**2c · Trust the new server 🤖**

1. Find the node named `vps` with `tailscale status --json`. Its address and name stay in memory, never in state or evidence.
2. Check that `ssh -G vps` points at that node; if not, it asks you to set `HostName` in `~\.ssh\config`.
3. Fetch the host keys with `ssh-keyscan` and **stop unless one has the fingerprint you gave**.
4. Only then file the matching keys in `known_hosts` in place of the old server's (hashed entries too; the old file is kept as `known_hosts.cria-<time>`), and check that `ssh vps true` logs in.

**2d · Base system over SSH 🤖**

`02-base.sh run` sets the VPS up as the live one was read on 7 October 2026. It checks first and changes only what differs, so it is safe to run again.

| Part | What |
|---|---|
| Packages | Docker Engine and the Compose plugin from Docker's apt repository (deb822, the key checked against Docker's fingerprint), pinned to the live versions; `nftables`, `iproute2`, `nginx`, `jq`, `ufw` and `unattended-upgrades` from Ubuntu's. Never `curl \| sh` (C-15). No `sqlite3`: the live VPS has none |
| Updates | Unattended upgrades on |
| Boot order | `net.ipv4.ip_nonlocal_bind = 1`, so nginx, Docker and sshd can bind the tailnet address before `tailscale0` has it |
| Routing rules | `systemd-networkd` keeps routing rules it did not create (`ManageForeignRoutingPolicyRules=no` in `/etc/systemd/networkd.conf.d/10-ollama-cria.conf`). By default it deletes them whenever it restarts: an automatic update on 4 October 2026 did, and wiped the guard's rules, its IPv6 block included |
| IPv6 | None on the public interface (`/etc/netplan/60-ollama-cria.yaml`: `dhcp6` off, no router advertisements, no link-local addresses), switched off at once with `sysctl` too. Tailscale keeps its IPv6 on `tailscale0` |
| Firewall | `ufw`: deny incoming and routed, allow outgoing; allow everything on `tailscale0`, and `41641/udp` for Tailscale's direct connections |
| SSH | Keys only, no root, listening on the tailnet address only. Done last, after checking that the VPS's own tailnet address is the one the PC sees, and kept only if `sshd -t` passes |

🛑 **Checkpoint 2**

| Who | Check | Expected |
|---|---|---|
| 🤖 | Node `vps` in the tailnet; the alias points at it | Yes |
| 🤖 | `known_hosts` | Only the key with the fingerprint from the console |
| 🤖 | `02-base.sh check` over `ssh vps`, as root with no password | Docker and Compose answer; every package installed; `ip_nonlocal_bind` is 1; networkd keeps the guard's routing rules |
| 🤖 | ufw | Active, with the defaults above; `tailscale0` and `41641/udp` let in, nothing else. (Listening sockets alone prove nothing; Stage 10 tests reachability from outside, C-52.) |
| 🤖 | sshd | Tailnet address only, no passwords, no root |
| 🤖 | `tailscale ping vps` from the PC | A reply |

---

# STAGE 3 · Windows runtime

> **Delivers:** the GPU checked, WSL2, Docker Desktop, Python 3.11, Ollama with the Machine-scope profile. **Nothing that writes stack data starts yet.** (ComfyUI moved to Stage 6 in v0.4.)
> **Where:** 🖥️ PowerShell 7, Admin: the controller opens an elevated window for this stage only
> **Module:** ✅ `windows\stages\03-runtime.ps1` (written fresh: not `windows\step2.ps1` and not its Full install mode, C-13)

**3a · Virtualisation and drivers**

1. Check that firmware virtualisation is on (`Get-CimInstance Win32_Processor`, `VirtualizationFirmwareEnabled`). If it is off, stop: that is a BIOS change 👤.
2. `wsl --install --no-distribution`, then record reboot-required and resume after the reboot.
3. NVIDIA driver: `nvidia-smi` must list the card recorded in `manifests\windows-apps.json`. If no driver answers, the stage asks you to install that driver version from nvidia.com (or let Windows Update do it) 👤. A different driver version only warns. On a machine without that card (a rehearsal), answer with `-Accept gpu`: ComfyUI and Ollama then run without CUDA.

**3b · Applications** (pinned versions from `manifests\windows-apps.json`)

| Package | winget ID |
|---|---|
| Docker Desktop | `Docker.DockerDesktop` |
| Ollama | `Ollama.Ollama` |
| Python 3.11 | `Python.Python.3.11` |
| Python 3.13 | `Python.Python.3.13`, for all users in `C:\Python313` |

Every package in the manifest is installed at its recorded version with `winget install --exact --version` (a row with `"exact": false` takes any version; a row with `"override"` hands its installer arguments to `winget --override`, which is how Python 3.13 lands in `C:\Python313`, the path the PowerShell tool's task and scripts run), then Docker Desktop and Ollama are pinned with `winget pin add` so `winget upgrade --all` never moves them (C-30). After each install the controller refreshes `PATH` in its own process. Installing Docker Desktop asks for a restart, because its `docker-users` group only counts from your next sign-in. Then the controller starts Docker Desktop **as you** (through Explorer, never as Admin) and waits until `docker info` answers, not just until the installer exits (C-53).

**3c · Ollama profile, Machine scope only** (C-12)

The controller writes every row of `manifests\ollama-env.json` (the `OLLAMA_*` profile below plus other Machine-scope runtime variables such as `HF_HOME`) at **Machine** scope, then removes any `OLLAMA_*` variable at **User** scope, then fully restarts Ollama (tray app quit, process gone, started again).

Live values captured on 5 October 2026:

| Variable | Value |
|---|---|
| `OLLAMA_FLASH_ATTENTION` | `1` |
| `OLLAMA_GPU_OVERHEAD` | `1073741824` |
| `OLLAMA_HOST` | `127.0.0.1:11434` |
| `OLLAMA_KEEP_ALIVE` | `45s` (Liam's selected policy, 5 Oct 2026) |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` (deliberate, don't "fix") |
| `OLLAMA_MAX_LOADED_MODELS` | `1` |
| `OLLAMA_MAX_QUEUE` | `512` |
| `OLLAMA_MODELS` | `E:\ollama-models` |
| `OLLAMA_NUM_PARALLEL` | `1` |

> ✅ **R-16 resolved:** Liam confirmed on 5 October 2026 that `45s` is the intended policy. `AGENTS.md` and the master document (Ch. 8.2, 13.6) were updated to match (`AICL-0127`).

**3d · ComfyUI** moved to Stage 6 (6 · ComfyUI) in v0.4.

🛑 **Checkpoint 3**

| Who | Check | Expected |
|---|---|---|
| 🤖 | `nvidia-smi` | The GPU and driver version from the manifest |
| 🤖 | `docker info --format {{.ServerVersion}}` | A server version (the engine, not only the CLI) |
| 🤖 | Every `OLLAMA_*` at Machine scope | Matches the manifest |
| 🤖 | Any `OLLAMA_*` at User scope | None |
| 🤖 | Virtualisation, WSL and the Virtual Machine Platform | On and ready |
| 🤖 | Every package in `windows-apps.json` | Installed |
| 🤖 | `winget pin list` | Docker Desktop and Ollama pinned |

---

# STAGE 4 · Render endpoints and place the remaining secrets

> **Delivers:** every config file filled in with the **new** tailnet addresses, and every remaining credential in its place with tight permissions
> **Where:** 🖥️ → ☁️ · 🔐
> **Modules:** ✅ `windows\stages\04-render.ps1`, ✅ `tools\Restore-StackSecrets.ps1`

**4a · Render the endpoint contract** (C-22)

The repo stores templates with placeholders such as `{{PC_TS_IP}}` and `{{VPS_TS_IP}}`, never the old addresses. The controller reads the new addresses and names from `tailscale status --json` (kept in memory only, never in state or evidence) and renders every file listed in `manifests\endpoints.json`: the PC compose file, the relay config, the VPS compose file, `guard.nft`, the nginx relay, CORS settings, scripts that dial the other host, and the OWUI seed's URLs. Appendix E lists the full contract. A placeholder with no value stops the stage.

Stage 4 writes **every** file in `manifests\stack-files.json`, templated or not: PC sources to their root (`E:\ai\ollama`, the dashboard folder), VPS sources under `E:\recovery-state\rendered\<source>\` for Stage 5 to copy, and `windows\` sources wait for Stage 8. A file that is not listed in `endpoints.json` must hold no placeholder. Each file is written under a new temporary name and moved into place without replacing anything. A file already there is left alone when it holds the same bytes, replaced only when the controller wrote it and nobody changed it since, and refused otherwise.

**4b · Place every remaining secret** 🤖

The bundle was downloaded, checked and unpacked in Stage 1. `Restore-StackSecrets.ps1` reads `00-RESTORE-MAP.json` and, for each row:

1. Checks the file's full SHA-256 and byte length against the map.
2. Resolves its **logical destination** (for example `stack:secrets/ntfy-publisher`) to a path under a configured root. The map never holds raw absolute paths, and every resolved path passes `Test-RecoveryPath` (C-49).
3. Copies it, on the PC or over SSH to the VPS.
4. Sets permissions per row: Windows ACL to the owner only; on Linux the owner and mode each service needs (`liam` `0600` by default; some containers read as their own user).
5. Fails on any missing **required** row. Optional rows only warn (C-07).

> 🔗 **One format for both ends (C-08):** the rewritten collector writes the same versioned `00-RESTORE-MAP.json` this helper reads, with unique case-insensitive destinations and full hashes. A bundle from the old collector is refused.

| Bundle folder | Contents | Goes to |
|---|---|---|
| 01 | Stack `.env`, Docker secrets in `E:\ai\ollama\secrets\`, the local SearXNG `settings.yml` | 🖥️ |
| 02 | Google OAuth client and tokens (gcal and Gmail bridges), the gcal bridge `watchdog.ps1` | 🖥️ |
| 03 | OWUI secret values the seed refers to: provider API keys, tool-server bearer tokens, the Groq STT key, Valve secrets, `WEBUI_SECRET_KEY` | 🖥️ (used in Stage 7) |
| 04 | SSH private key, public key and config | 🖥️ (placed in Stage 1) |
| 05 | VPS web egress `.env` (WireGuard keys, Brave key, SearXNG secret) | ☁️ |
| 07 | Service state: ntfy `user.db`, Bolt `server-keys.json` | 🖥️ (used in Stage 7) |

> ℹ️ There is no folder 06 any more. The Groq STT relay on the VPS adds no credential; OWUI sends the Groq key itself (checked live on 5 October 2026), so that key travels in folder 03.

🛑 **Checkpoint 4**

| Who | Check | Expected |
|---|---|---|
| 🤖 | Every rendered file: no placeholder left, and no tailnet address but the new nodes' own | All of them |
| 🤖 | Restore map: required rows placed, hashes and lengths matching | All of them |
| 🤖 | `ssh vps 'stat -c "%a %U %n" ~/owui-web-egress/.env'` | `600 liam` |
| 🤖 | Evidence files tested against every bundle value (match test only, nothing printed) | No matches |

---

# STAGE 5 · VPS: guard, web egress, Kokoro and the STT relay

> **Delivers:** the whole VPS side: the nftables guard, gluetun/Mullvad, SearXNG, searxng-mcp, Jina Reader, the Brave/Jina gateway, the relay, Kokoro and the Groq STT relay
> **Where:** ☁️, driven from 🖥️
> **Modules:** ✅ `windows\stages\05-vps.ps1`, `linux\stages\05-place.sh`, `linux\stages\05-services.sh`; restore-only files in `linux\files\web-egress\`

**5a · Place the files 🤖**

Every VPS file Stage 4 rendered (`E:\recovery-state\rendered\`) goes to its folder from `manifests\stack-files.json`: `~/owui-web-egress`, `~/kokoro`, `/etc/nginx/sites-available/groq-relay` and Docker's drop-in `/etc/systemd/system/docker.service.d/owui-web-egress.conf`. The guard's unit also goes to `/etc/systemd/system/`, and the restore-only files (5c) into `~/owui-web-egress`. Files under `/home/liam` belong to `liam` (scripts 0755, the rest 0644); files under `/etc` to root (0644). `05-place.sh` writes each one:

- only under `/home/liam/`, `/etc/systemd/system/` and `/etc/nginx/sites-available/`, and never through a link;
- checked against its SHA-256 after the trip;
- never over a file it did not write. Its ledger, `/var/lib/ollama-cria/placed`, records what it wrote, so a rerun replaces only its own files that nobody has changed since.

**5b · The guard first** (C-20, C-43)

1. Enable the guard's unit and start it. A guard that is already running restarts only when one of its files has just changed, because Docker `Requires=` it and systemd restarts Docker, with every container, whenever the guard restarts.
2. Prove its rules are loaded: the `inet owui_web` nftables table, routing rule `5260` and the IPv6 block, rule `5265 prohibit`, exist. `active` alone is not enough.
3. Prove Docker needs it: `systemctl show docker` lists the guard in `Requires=` and `After=` (the drop-in, C-43).

No image is pulled and no container is created until all three pass.

**5c · Images** (R-13)

| Service | Image source | Action |
|---|---|---|
| gluetun, SearXNG, socat relay, Kokoro | Registry, digest from `manifests\images.json` | Pull by digest, then tag as the compose file names it |
| Brave/Jina gateway | `python@sha256:dd29…` plus the mounted `brave_jina_gateway.py` | Pull by digest |
| Jina Reader | `jina-official\Dockerfile` + `harden-reader.js` | **Build** and tag `jina-reader-official-hardened:2026-09-24` |
| searxng-mcp | Live: a bare local image ID (`sha256:afd7…`) that no registry holds | **Build** from `linux\files\web-egress\searxng-mcp\Dockerfile` (`mcp-searxng@1.6.0` on a pinned `node:22-alpine`) and tag `searxng-mcp:1.6.0`. `compose.override.yml`, placed beside the compose file, points the service at it |

An image that is already there is left alone.

**5d · The two compose projects**

`docker compose up -d --pull never --wait` in `~/owui-web-egress`, then in `~/kokoro`. `--pull never` means only the images above can run; `--wait` holds until every service is running and healthy (5 minutes at most). It needs `/dev/net/tun` and the egress `.env` from Stage 4.

All egress services except gluetun use `network_mode: "service:gluetun"`, so they can reach the internet only through the tunnel. Kokoro (`ghcr.io/remsky/kokoro-fastapi-cpu:v0.5.0`, R-14) listens on `{{VPS_TS_IP}}:8880` only.

**5e · Groq STT relay** (C-25)

Only `groq-relay` is switched on in `sites-enabled` (listening on `{{VPS_TS_IP}}:18099`), and the package's `default` site is switched off. Then `nginx -t`, and reload. The relay adds no credential; OWUI sends the Groq key. No other nginx site comes across.

🛑 **Checkpoint 5**

| Who | Check | Expected |
|---|---|---|
| 🤖 | Guard unit | Enabled and active |
| 🤖 | nftables table `inet owui_web`, routing rule 5260 and IPv6 block 5265 | Present |
| 🤖 | `systemctl show docker -p Requires -p After` | Both list the guard |
| 🤖 | Egress project and Kokoro | Every service running; gluetun `healthy` |
| 🤖 | Exit address from **inside** the gateway's namespace vs the VPS's own | Different (C-21). Only "same" or "differs" is recorded, never the addresses |
| 🤖 | `ss -Hltn` on the VPS | 8880, 18099 and 13100 on the tailnet address only (reachability from outside is tested in Stage 10) |
| 🤖 | nginx | Relay site on; `nginx -t` passes |
| 🤖 | From the PC: `:13100/health`, `:8880/v1/models`, and a SearXNG search on `:18080` | Healthy; lists `kokoro`; returns results |

> 🧪 **Kill-switch test (C-21):** stopping the tunnel and proving that traffic fails closed is done in Stage 10 on the rebuilt host, not here, and never on the working VPS.

---

# STAGE 6 · Fetch models and weights

> **Delivers:** ComfyUI at its pinned commit with its venv and custom nodes, every Ollama model and every ComfyUI weight, each downloaded from its origin and checked
> **Where:** 🖥️ PowerShell 7, as you (needs Stages 1 and 3; can run before Stages 2, 4 and 5)
> **Module:** ✅ `windows\stages\06-fetch.ps1` with `manifests\comfyui-nodes.json`, `comfyui-requirements.lock`, `ollama-models.json` and `comfyui-weights.json`

**6 · ComfyUI at a pinned commit** (C-18; was 3d)

```powershell
git clone --no-checkout https://github.com/comfyanonymous/ComfyUI E:\ai\comfyui\ComfyUI
git -C E:\ai\comfyui\ComfyUI checkout --detach bb131be9e83d2f773c90f1d6f1e4b248a498c8c5
py -3.11 -m venv E:\ai\comfyui\ComfyUI\.venv
```

Then the controller installs packages from `manifests\comfyui-requirements.lock` with **both** index URLs every time, so the CUDA wheels resolve (`--index-url https://download.pytorch.org/whl/cu124 --extra-index-url https://pypi.org/simple`), and clones each custom node at the commit listed in `manifests\comfyui-nodes.json` (ComfyUI-Manager included). Nodes listed under `manual` are reported for you to install by hand. A ComfyUI folder or venv the controller did not create is only checked, never changed; a clone of its own that never finished is removed and cloned again.

**6a · Ollama** (C-17; `pullall.ps1` is not used because it only refreshes models that are already installed)

Ollama is started as you if it does not answer, and free space on the model drive is checked first. For each row: `ollama pull <name:tag>`, then compare the digest with the manifest. **If the digest differs** (the tag has moved on), the controller pauses and asks Liam to accept the newer build (`-Accept 'model:<name>'`) or stop; it never swaps silently (C-48). Custom models whose base can't be re-downloaded have that base mirrored as a named resource in the manifest. Custom models (rows with `"modelfile"`) are rebuilt with `ollama create <name> -f manifests\modelfiles\<name>.Modelfile` after their base model is pulled. 45 models today.

**6b · ComfyUI weights**

Each row has `url`, `dest` (relative to `models\`), `bytes`, `sha256`, `role` and `auth` (none, Hugging Face token, or Civitai token). The fetcher:

1. Checks free space, then downloads with `curl` to `<dest>.partial`, resuming if a partial file exists. Links are `https` only, also after redirects.
2. Checks SHA-256 and size.
3. Only then renames to the final name.
4. Fails the stage if any **required** row fails. Placeholder and cache rows are not weights and are not in the manifest.

**6c · Gated models** 👤

Rows with `auth` other than `none` pause for Liam to accept the licence in the browser and keep the token in Bitwarden. Copy the token into a new file `E:\recovery-secrets\download-tokens\<auth>-token.txt` (`civitai` or `huggingface`), one line, and run again. The controller reads it from there, never from the command line, and hands it to `curl` in an owner-only header file it deletes straight afterwards; `curl` does not send it on after a redirect to another host (C-14). Stage 11 deletes the token file.

🛑 **Checkpoint 6**

| Who | Check | Expected |
|---|---|---|
| 🤖 | ComfyUI and every custom node | At their commits |
| 🤖 | `.venv\Scripts\python -c "import torch; print(torch.cuda.is_available())"` | `True` (or `-Accept gpu` given in Stage 3) |
| 🤖 | `ollama list` vs `ollama-models.json` | Every row present, digests matching (or accepted) |
| 🤖 | Weights fetcher summary | Every required row `verified`; zero `failed` |
| 🤖 | `mxbai-embed-large` present | Yes (OWUI's embedding model) |

---

# STAGE 7 · Images, volumes, service state and the OWUI functional seed

> **Delivers:** every local image, every Docker volume, the small service state from the bundle, and an OWUI database that holds your tools, functions, skills, model presets, settings and user settings, with no chats
> **Where:** 🖥️ PowerShell 7
> **Modules:** ✅ `windows\stages\07-state.ps1`, ✅ `tools\Import-OwuiSeed.py`, `manifests\owui-api-consumers.json`

**7a · Build local images first** (moved from Stage 8, C-36)

For each PC compose project (`ollama`, `gmail-owui-bridge`, `cline-dashboard`), `docker compose build` runs first; every image the project names that is still missing is then pulled **at its digest** and tagged as the compose file names it. OWUI comes from the digest the seed records (C-40); the rest from `manifests\images.json`. An image with nothing to build it from and no pinned digest stops the stage.

| Image | Build from |
|---|---|
| `mcpo-core-baked:pinned` | `Dockerfile.mcpo` |
| `bolt-baked:pinned` | `bolt\Dockerfile.bolt` |
| gcal bridge | `gcal-owui-bridge\` |
| Gmail bridge | `gmail-owui-bridge\` (own compose project) |
| Homelab dashboard | `E:\ai\ag-startuip\cline-dashboard` (own compose project) |

Registry images (OWUI at its **recorded** digest, Tika, Playwright MCP, ntfy, Dozzle, open-terminal, the pinned `python@sha256:423ed6ab…` for `web-vps-relay`) are pulled in the same step. Nothing is created until every image is present.

**7b · Volumes**

```powershell
docker volume create --label ollama-cria.stage=7 owui-data                  # external: true in the compose file
docker compose create --pull never --no-build --no-recreate                # each project: volumes and containers; starts nothing
```

The label is how the controller knows `owui-data` is its own. An `owui-data` without it is **refused**: never used, never removed (see Controller → Ownership).

**7c · Small service state** (from bundle folder 07; R-08, R-09)

| Volume | File | Why it matters |
|---|---|---|
| `ollama_ntfy-data` | `user.db` | Phone and publisher accounts, tokens and permissions. Without it the phone must be re-paired. |
| `ollama_bolt-data` | `server-keys.json` | Bolt's server identity. Without it every Bolt client must be re-keyed. |
| `ollama_mcpo-core-data` | `config.runtime.json` | **Not restored.** mcpo regenerates it from `mcpo-core-config.pinned.json` (proof required, R-09) |

The rewritten collector captures `user.db` with SQLite's backup API, so the copy is consistent and there is no `-wal` file to lose (C-03). Restore copies it in with the container stopped, through a throw-away helper container of the `web-vps-relay` image (pinned `python@sha256:…`, no network).

**7d · The OWUI functional seed** (R-17)

The seed lives at `manifests\owui-seed\` and is produced by 🛠️ `tools\Export-OwuiSeed.py`, which runs **inside** the OWUI container:

- **One consistent snapshot.** All tables are read in one read-only transaction.
- **Allowlist schema** (`owui-seed\schema.json`). Every field is classified as *repo-safe*, *secret reference* (value goes to bundle folder 03), *excluded*, or *unknown*. **An unknown field stops the export** (C-41).
- **OWUI's own Valve codec.** Valves are decrypted in memory with OWUI's code, classified, and written out as plain settings plus secret references. No ciphertext ever reaches the repo; a decryption failure stops the export (C-39).
- **Provenance.** The seed records the OWUI version (0.11.4 today), the image digest and the Alembic revision (`d4c1a8e37b62` today) (C-40).
- **Scan before commit.** A test with fake secrets proves the export never contains secret-shaped values.

| What | Rows today | In the seed | Notes |
|---|---|---|---|
| `config` | 409 | ✅ | Secrets become references; URLs templated |
| `tool` | 15 | ✅ | Source, specs and Valves (via the codec) |
| `function` | 5 of 6 | ✅ | 1 pipe, 3 filters, 1 event. `discord_feed_curator` is retired and excluded |
| `model` | 33 | ✅ | Model presets |
| `skill` | 21 | ✅ | |
| `prompt` | 5 | ✅ | |
| `group`, `group_member`, `access_grant` | 1, 0, 15 | ✅ | Only grants whose resource is in the seed |
| `user.settings` (allowlisted part) | 1 | ✅ | Pinned and selected models, function-calling and tool-approval modes, TTS choices, per-user tool Valves including the sub-agent prompt (C-37) |
| The `user` account itself, `auth`, `api_key` | 1 | ❌ | Created fresh in step 3 below |
| `channel`, `channel_webhook`, `channel_member` | 1, 1, 1 | ❌ | 🗄️ Retired with the Discord bridge |
| `chat`, `file`, `note`, `memory`, `calendar_event`, `automation_run` | 97, 218, 18, 1, 628, 6 | ❌ | Content, not capability |
| `knowledge`, `automation` | 0, 0 | — | Nothing to carry |

**Tools in the seed:** `brave_reader`, `brave_research`, `brave_search`, `cited_analysis`, `extract_schema`, `generate_audio`, `generate_image`, `generate_video`, `local_subagent`, `model_feature_manager`, `nvd_recent_cves`, `self_osint_footprint_recon_removal_uk`, `smart_read_aloud`, `windows_powershell`, `youtube_channel_videos`.

**Functions in the seed:** `brave_command_router` (filter), `comfyui_studio` (pipe), `mermaid_modern_style` (filter), `mermaid_render_guard` (filter), `ntfy_push` (event).

**How the seed is installed**

1. **Schema.** The controller starts OWUI alone at the recorded version (`docker compose up -d --no-deps open-webui`), reachable on `127.0.0.1:3000` only. It creates its empty schema.
2. **Admin account** 👤. While OWUI has no account, the stage stops with an `ASK`: open `http://127.0.0.1:3000`, create the admin account (the first account is the admin), then run the same `-Execute` again.
3. **Check and import, with OWUI stopped.** `Import-OwuiSeed.py` runs in a new container of the same service (`docker compose run --rm --no-deps -T`), with the seed, the secrets file from bundle folder 03 and the new tailnet addresses on its **standard input**, never on a command line. It refuses to continue unless the database's version and Alembic revision match the seed (C-40) and the database is fresh: one admin, nothing in the seeded tables. In one transaction it writes the seed rows and points **every** owner and member reference at the new admin: tools, functions, models, skills, prompts, groups, group members and grants (C-38). It applies the `user.settings` projection to the new admin, fills each secret reference, and encrypts Valves through OWUI's own code with this install's `WEBUI_SECRET_KEY`. It then checks that no reference to the old user ID remains. A rerun that finds the seed already in does not import it twice.
4. **API key** 👤. The controller starts OWUI alone again, writes an empty owner-only `E:\recovery-secrets\owui-api-key.txt`, and asks you to create a key in Settings → Account → API keys and paste it there; then run the same `-Execute` again. The key must open OWUI's calendar API, then goes into every consumer in `manifests\owui-api-consumers.json`. That is only the gcal bridge's `.env` (`OWUI_API_KEY`): the code was read on 7 October 2026, and the Gmail bridge and the dashboard never call OWUI. This is the one time a fresh key is correct. OWUI is stopped again; nothing runs until Stage 8, which recreates the gcal bridge with the new key. Stage 11 deletes the key file.
5. **Upgrade later.** OWUI stays at the recorded version until Stage 9 passes, then moves to `latest` by the normal update route (C-40).

> ⚠️ `ENABLE_PERSISTENT_CONFIG=true` means the `config` table wins over compose environment variables. That is why the settings travel in the seed, not in `.env`.

🛑 **Checkpoint 7**

| Who | Check | Expected |
|---|---|---|
| 🤖 | Every image of the PC compose projects present locally; OWUI's at the seed's digest | Yes (and none was created before they were, C-36) |
| 🤖 | `owui-data` | Carries this stage's label |
| 🤖 | Row counts for the seeded tables (tool, function, model, skill, prompt, group, group member, grant) | The counts the seed's provenance records (15 / 5 / 33 / 21 / 5 / … today) |
| 🤖 | `{{OWNER}}` or `{{BUNDLE:…}}` left anywhere in them | **Zero** |
| 🤖 | Accounts | One |
| 🤖 | Secret references | Every **required** one resolved (the importer stops otherwise); optional ones may stay blank by design (C-50) |
| 🤖 | `PRAGMA integrity_check` and `PRAGMA foreign_key_check` | `ok` and no rows |
| 🤖 | ntfy and Bolt files in their volumes, hashes matching the map | Placed |
| 🤖 | Every API key consumer | Holds a key, and the key opened OWUI's calendar API when it was placed |

What you see in OWUI (functions, pinned models, the sub-agent prompt) is tested in Stage 9.

---

# STAGE 8 · Start services, Tailscale Serve and automation

> **Delivers:** the whole PC stack running, reachable on the tailnet, and coming back on its own after a reboot
> **Where:** 🖥️ PowerShell 7; the controller opens an elevated window for this stage
> **Modules:** ✅ `windows\stages\08-serve.ps1`; ♻️ `start-stack.ps1` (C-27)

The stage works for the account signed in at the console. If the admin prompt is answered as another account, it stops, because the tasks and startup items would be that account's.

**8a · Port, firewall and pagefile** (C-31, C-52, R-07)

| Item | What the controller does |
|---|---|
| Port 8188 | Reserves it as an administered TCP exclusion, so WinNAT cannot take it after a restart. Only when it is not reserved: stops `winnat`, adds the range, and starts `winnat` again even when adding failed (C-31) |
| Firewall | Adds the inbound rule **ComfyUI 8188 - loopback and tailnet only**: TCP 8188 from `100.64.0.0/10` and `127.0.0.1`, every profile, as on the old PC (read 7 October 2026). ComfyUI keeps `--listen 0.0.0.0`; the containers reach it through Docker Desktop, which connects from this PC. Any other rule that lets a wider network reach 8188 stops the stage with an ASK to turn it off (C-52) |
| Pagefile | `C:\pagefile.sys` 32768–81920 MB with Windows' own management off, set only if different. It takes effect at the restart in Stage 10 |

A rule or setting the controller did not make is reported, never changed.

**8b · Start in order**

1. Ollama (native) is already running from Stage 6; the controller starts it as you if it is not.
2. ComfyUI: the controller copies `start_comfyui_hidden.vbs` into your Startup folder (8d), starts it once as you, and waits for `/system_stats` to answer.
3. `start-stack.ps1` brings up the 10 PC compose services with their normal dependencies (tika, playwright-mcp, web-vps-relay, mcpo-core, open-webui, gcal-owui-bridge, ntfy, bolt, dozzle, open-terminal), then the Gmail bridge and dashboard projects.
4. The controller then checks for itself, because `start-stack.ps1` still exits 0 when a service is down:
   - every service of every PC compose project is running, and healthy where it has a health check;
   - every container runs its current configuration (`docker compose config --hash` against the container's label). A container left from Stage 7 with older settings, such as the gcal bridge before its new API key, is recreated;
   - 12 health URLs on this PC answer **200**: OWUI, mcpo-core, open-terminal, SearXNG and Jina Reader through the relay, both bridges, ntfy, Dozzle, the dashboard, ComfyUI and Ollama. Bolt publishes only on the tailnet address, so its health check and Stage 9 cover it.
5. The controller reads OWUI's tool catalogue with the Stage 7 API key and checks that every tool server the seed enables is listed (18 today). If one is missing, it restarts OWUI once, in case OWUI cached its list while mcpo was still starting. If OWUI will not show the list to the key, it asks you to check the tool servers in OWUI's admin settings and run again with `-Accept tool-catalogue`.

> ♻️ **C-27:** `start-stack.ps1` must exit non-zero when a required service fails, and a 401/404/500 response must count as a failure for health checks that expect 200. That is a change to a live file and waits for Liam. Until then Stage 8 applies the rule itself.

**8c · Tailscale Serve** (C-23; tailnet only, **never** Funnel)

From `manifests\serve.json`, only the rules that are missing:

```powershell
tailscale serve --bg --tcp=11434 tcp://127.0.0.1:11434   # Ollama
tailscale serve --bg --tcp=8188  tcp://127.0.0.1:8188    # ComfyUI
tailscale serve --bg --https=443  http://127.0.0.1:3000  # OWUI
tailscale serve --bg --https=444  http://127.0.0.1:8188  # ComfyUI (HTTPS)
tailscale serve --bg --https=2000 http://127.0.0.1:6080  # Dashboard
tailscale serve --bg --https=8443 http://127.0.0.1:8090  # ntfy
tailscale serve --bg --https=9000 http://127.0.0.1:18088 # Dozzle
```

A port that already serves something else, a rule that is not in `serve.json`, or Funnel on any port is reported with the command that turns it off. The controller never changes them.

**8d · Startup items and scheduled tasks** (C-28, R-10, R-11)

| Item | Kind | Action |
|---|---|---|
| `start_comfyui_hidden.vbs` | File in your Startup folder | Copied from `windows\startup\` (8b); it runs the venv with `--listen 0.0.0.0 --port 8188` |
| `OWUI ComfyUI AutoFree.lnk` | Shortcut in your Startup folder | Made from `tasks.json`: PowerShell 7 running `autofree-watchdog.ps1` |
| `OWUI-Stack-Startup`, `OWUI-mcpo-Watchdog` | Scheduled tasks | Imported from XML like the rest. The XML is the live definition; the installer scripts in the stack would make a different task (the watchdog runs as S4U on the old PC, and its installer makes it interactive) |
| `OWUI-ntfy-Fast`, `OWUI-ntfy-PcHealth`, `Tailscale-Status-Feed`, `LibreHardwareMonitor` | Scheduled tasks | Imported from `windows\tasks\*.xml` with your SID, account name and profile folder filled in |
| `OWUI-ntfy-MorningBrief` | Scheduled task | Imported **disabled**, as it is today |
| `OWUI-Windows-PowerShell-Tool` | Scheduled task | Imported from XML; its broker token came from bundle folder 01 in Stage 4. It runs `C:\Python313\python.exe`, which Stage 3 installs there |

A task is imported only when it is missing, and only once the scripts it runs (`runs` in `manifests\tasks.json`) and the programs its XML names are on this PC; otherwise the stage names what is missing. A task already there is left alone, except that one the manifest has disabled is disabled. Tasks that start only at sign-in (the PowerShell tool's broker and LibreHardwareMonitor) are started once now, so Stage 9 finds them running. `OWUI-Stack-Startup` is not, because the stage has just done its work. Stage 10 proves each task actually ran (a log line or heartbeat), not only that it shows `Ready` (C-51).

🚫 **Not recreated:** the retired backup tasks `OWUI-Nightly-Backup`, `OWUI-Weekly-VPS-Push`, `OWUI-ntfy-Backups` and `Ollama Weekly Backup`; and `OWUI-Automation-Chat-Tidy` with its script `kais_chat_tidy.ps1` (failing daily with 401 since at least 1 October; the automations it tidied no longer exist; R-20). Stage 10 sets up the replacement backup routine.

> 💡 **Updates (C-30):** winget pins on `Ollama.Ollama` and `Docker.DockerDesktop` stop **winget** upgrading them. They do not stop Ollama's own tray updater. Pins are set, and the updater policy is ❓ **R-18**.

🛑 **Checkpoint 8**

| Who | Check | Expected |
|---|---|---|
| 🤖 | Port 8188 | Reserved (an administered exclusion) |
| 🤖 | Firewall | The ComfyUI rule in place; no other rule opens 8188 beyond the tailnet |
| 🤖 | Pagefile | 32768–81920 MB, or set and waiting for the restart in Stage 10 |
| 🤖 | Startup items | Both in place |
| 🤖 | `start-stack.ps1` exit code | `0` |
| 🤖 | Compose services | All 10, plus the Gmail bridge and the dashboard, running and healthy, each on its current configuration |
| 🤖 | Health URLs | All 12 answer 200 (C-27) |
| 🤖 | OWUI tool catalogue | Every tool server the seed enables (18) |
| 🤖 | `tailscale serve status --json` vs `serve.json` | Exactly the seven rules; Funnel off |
| 🤖 | Scheduled tasks | Each present, MorningBrief disabled |
| 👤 | OWUI opens on the PC's tailnet name from the phone | Yes; then run again with `-Accept owui-phone` |

---

# STAGE 9 · Functional tests

> **Delivers:** proof that each capability **works**, not just that its container is up
> **Where:** 🖥️ and 👤, from a browser and the phone
> **Module:** ✅ `windows\stages\09-acceptance.ps1` with `manifests\acceptance.json` and `linux\stages\09-reach.sh`

`acceptance.json` has **one row per capability** (C-46). An 🤖 row holds one safe call: read-only, or a search, a page read or a short piece of speech, none of which changes anything outside the stack. A 👤 row is for something with a real-world effect (a notification, media, a voice in your ears) or something only you can see.

**What the stage does**

1. **Coverage.** Every tool (15) and function (5) in the seed must be named by a row, and every tool server the seed switches on must match exactly one row. A gap either way is a failure: add or remove the row. A tool server row the seed does not switch on (for example `github`) is skipped.
2. **The 🤖 rows**, one call each. The credentials come from the OWUI API key Stage 7 left and the `.env` files Stage 4 rendered. They stay in memory, and no answer is written down: the evidence holds only the HTTP status and whether the answer held what the row expects.
3. **One row per model preset in the seed.** An active preset must show the seed's tools, skills, filters and actions in OWUI (each skill there, on or off as seeded) and answer *"Reply with the single word OK."* through OWUI's chat API, which saves no chat. A preset built on the `comfyui_studio` pipe is not asked, because it makes media: the media 👤 row covers it. An inactive preset is not asked either.

Each failure names the stage that owns it. The stage stops at once if the seed is not in the repo or OWUI refuses the API key.

| # | Capability | 🤖 rows | 👤 row |
|---|---|---|---|
| 1 | Local inference | Ollama lists its models | Chat with a local model; `ollama ps` shows 100% GPU (`local-chat`) |
| 2 | Cloud providers | | One message each through OpenAI, Anthropic and Cline (`cloud-chat`) |
| 3 | Tool servers | Each mcpo-core server answers one call with the stack's key (for example `time`: `get_current_time`; `memory`: `read_graph`; `shodan`: a DNS lookup, which uses no credits). `censys`, `security_tools` and `github` only list their tools: none of their tools is known to be free and read-only. open-terminal answers `GET /files/cwd`; both bridges serve their OpenAPI description | |
| 4 | Web search | `brave_search` and `brave_research` load; the VPS gateway is up with its Brave key, and returns a search and a research answer; SearXNG returns results through the relay | |
| 5 | Page reading | `brave_reader` loads; Jina Reader on the VPS reads a page through the gateway | |
| 6 | Image and video | `generate_image`, `generate_video` and `comfyui_studio` load | Each makes something that opens (`media`) |
| 7 | Speech to text | The Groq relay answers on the VPS's tailnet address | Dictate a sentence; the text appears (`stt`) |
| 8 | Text to speech | Kokoro on the VPS speaks a sentence with `af_heart` | Read aloud uses `af_heart` (`tts`) |
| 9 | Notifications | `ntfy_push` loads | One notification reaches the phone (`ntfy`) |
| 10 | Calendar and Gmail | Both bridges hold a Google token; the gcal bridge lists the next day's events and the Gmail bridge reads the mailbox profile, live from Google. A failure here means re-consent (the bridge's `/auth/url`) | |
| 11 | Filters | `brave_command_router` and both Mermaid filters load | A command routes; a Mermaid diagram renders (`filters`) |
| 12 | Bolt and open-terminal | From the VPS, on the PC's new tailnet address: Bolt answers on 3001 (any answer: it wants a token), open-terminal's `/health` gives 200 on 18019 | |
| 13 | Model presets and skills | Every preset, as above | |
| 14 | Other tools | The 10 other tools load; the PowerShell tool's broker is up and runs one read-only command | Each tool once in a chat (`other-tools`) |
| 15 | Dashboard and Dozzle | | Both open through Serve from the phone (`serve-pages`) |

"Loads" means OWUI imports the tool's or function's code (`/valves/spec`), which also installs its requirements: a missing package fails here, not in your first chat.

🛑 **Checkpoint 9**

| Who | Check | Expected |
|---|---|---|
| 🤖 | Coverage | Every tool, function and tool server in the seed has a row |
| 🤖 | Each group's 🤖 rows | All pass |
| 👤 | Each 👤 row | Done, then run again with `-Accept local-chat,cloud-chat,media,stt,tts,ntfy,filters,other-tools,serve-pages` (or any of them as you go) |

The checkpoint reads the results the last run recorded and calls nothing; to test again, run `-Stage 9 -Execute` (Stage 10 does, after the reboot).

---

# STAGE 10 · Reboot, rerun and the backup routine

> **Delivers:** proof that it survives a reboot, an interruption and a second run, that nothing answers from outside the tailnet, that the VPS fails closed, plus a first backup and the routine that keeps it current
> **Where:** 🖥️ and ☁️, with 👤 for the restart, the phone and Bitwarden
> **Modules:** ✅ `windows\stages\10-rehearsal.ps1`, `linux\stages\10-vps.sh`, `linux\stages\10-killswitch.py`, `windows\reminder\`

The stage takes several visits: run the same `-Execute` command again after the restart and after each answer. A part that passed is not run again; one that failed runs again on the next visit.

**10a · Restart the PC** 👤🤖

The first visit records when Windows last started and stops with exit code 3. Restart (Start → Power → Restart), sign in, wait for the desktop, and run the same command again. Then:

1. Checkpoint 8 must pass again, waiting up to ten minutes for the stack. The pagefile must now be in effect.
2. Stage 9's 🤖 rows run again.
3. Every scheduled task and startup item must show it ran since the restart (C-51): a line its script logs (`mcpo-watchdog.log`, `ntfy-monitor.log`, `autofree.log`), a file it writes (`start-stack-*.log`, the dashboard's `tailscale-status.json`), Task Scheduler showing it running (the PowerShell tool, LibreHardwareMonitor), or ComfyUI answering. The stage waits until 25 minutes after the restart for them.

**10b · From outside the tailnet** 🤖 (C-52)

- This PC must not use a Tailscale exit node during this part: through one, its probes would leave from the tailnet and its public address would be the exit node's. The stage checks `tailscale status` and probes nothing while an exit node is on.
- The VPS reports its public IPv4 and IPv6 from the host, not the tunnel, and every TCP port anything listens on (`10-vps.sh public-ip`). This PC asks `api.ipify.org` and `api6.ipify.org` for its own.
- This PC probes the VPS's public addresses on those ports and the stack's (Appendix E, 22, 80, 443 and the rest). The VPS probes this PC's public addresses on the stack's ports and Windows' own (135, 139, 445, 3389, 5985 and the rest) with `10-vps.sh probe`. **Nothing may answer.**
- An address is probed only from a host with the same family, so a missing IPv6 route never reads as a closed port. A side with no IPv6 is a warning; IPv4 must be probed.
- This is the one place a stage script prints an address. The controller keeps the addresses in memory; the evidence holds families and ports only.
- 👤 **The LAN.** From the phone on the home Wi-Fi with Tailscale switched off, open `http://<this PC's LAN address>:3000`, then `:8188`, `:11434` and `:6080` (`ipconfig` shows the address). None may load. Then run again with `-Accept lan-closed`.

The phone on the tailnet is Stage 9's `serve-pages` row.

**10c · The VPS tests** 🤖, only after `-Accept vps-tests`

They restart the VPS, break its egress guard on purpose and stop its VPN tunnel, so web search, page reading and speech are down for a few minutes. Run them only on the **rebuilt** VPS, when nothing needs it for twenty minutes. They run only while checkpoint 2 passes, that is while `known_hosts` holds the host key you checked on the console, and each runs only after the one before it passed.

1. **Restart the VPS.** It must come back with a new boot ID, the guard active **before** Docker started, and the egress and Kokoro projects up with gluetun healthy. Checkpoint 5 must pass again.
2. **Break the guard on purpose.** A drop-in under `/run` (gone after any boot) makes the guard fail; with Docker and the guard stopped, systemd must **refuse to start Docker** (C-20, C-43). Then the drop-in goes, the guard and Docker start, and both projects must come back healthy. A trap restores everything on any exit.
3. **Kill switch.** `10-killswitch.py` runs inside the Brave/Jina gateway's container, which shares gluetun's network. It stops the tunnel through gluetun's control server, and everything must **fail closed** (C-21): the gateway's search and page reading, Jina Reader, SearXNG, both HTTP proxies, a direct connection over IPv4 and IPv6, a lookup of a new name, and plain DNS to two public resolvers. Each search and page carries a word made up for this run, so no cache can answer. The tunnel must still be stopped at the end. Then it starts the tunnel again, and a search must work. A trap starts the tunnel on any exit. If gluetun's control server ever asks for credentials, the test changes nothing and fails; it needs the same unauthenticated route as the live `verify_killswitch.py`.

**10d · The monthly reminder** 🤖👤 (C-47)

`windows\reminder\Send-BackupReminder.ps1` goes next to `NtfyCore.psm1` in `_support\scripts\scheduled\`, and the task `OWUI-ntfy-BackupReminder` is registered for this account: on the 1st of each month at 10:00, through `run-hidden.vbs`. The stage starts it once, and its log line must show ntfy took the notification. When *Monthly backup check* is on your phone, run again with `-Accept reminder`.

The reminder lists the routine: pull `main` into `E:\recovery` and run the collector there, upload the bundle to Bitwarden with its SHA-256, download it again and compare (the round trip), delete both copies with Shift+Delete (nothing may wait in the Recycle Bin), then commit the new seed and push. Any change to a key, token, tool, function or model preset is a reason to run it early. This replaces the retired backup tasks.

**10e · The first backup** 🤖👤, once 10a has passed

1. 🤖 `tools\Collect-StackSecrets.ps1 -Execute` runs on the new system into `E:\recovery-secrets\`, and writes the OWUI seed to `E:\recovery-state\owui-seed-new`, **not** into the repo. Changing `manifests\` now would stop every later stage at the release check; Stage 11 says how to commit it.
2. 👤 Upload the new `stack-secrets-<date>.zip` to the bundle's Bitwarden item, replacing the old attachment, with its SHA-256 (the stage prints it) in the notes.
3. 👤 Download it from Bitwarden into `E:\recovery-secrets\roundtrip\` (owner-only, made by the stage) and run again. Its SHA-256 must match.

The collector's run folder and the round-trip folder are recorded as plaintext, so Stage 11 removes them.

**Interruption test** 👤🤖 (C-45), **optional**

A real rebuild can skip it: it tests the controller, and the controller's own tests already prove the wipe and rerun. Without it, the checkpoint row reads `not run` and passes; a stage interrupted and not finished since still fails it. To run it: `-Execute -Stage 9`, and press **Ctrl+C** once it says `running`. Run the same command again: it must say Stage 9 was interrupted and finish with checkpoint 9 passed. Then run Stage 10 again. Any stage from 1 to 9 counts; Stage 9 is the quickest and changes nothing. `state.json` counts the interruption, and this stage compares the count with the one it recorded on its first visit. That only what a stage owns is wiped is proved by the controller's tests (`tests\Invoke-StackRecovery.Tests.ps1`), not again here.

**10f · The second run** 🤖, last

Once everything above has passed and been answered, every checkpoint from 1 to 9 runs again. All must pass, changing nothing.

🛑 **Checkpoint 10**

| Who | Check | Expected |
|---|---|---|
| 🤖 | After the PC restart: checkpoint 8 with the pagefile in effect, Stage 9's 🤖 rows, every task and startup item's sign of life | All pass |
| 🤖 | From outside the tailnet, both hosts | Nothing answers |
| 👤 | The PC's LAN address from the phone, Tailscale off | Nothing loads (`-Accept lan-closed`) |
| 🤖 | VPS restart | Guard before Docker; checkpoint 5 passes (after `-Accept vps-tests`) |
| 🤖 | Guard broken on purpose | Docker refuses to start, then everything returns |
| 🤖 | Kill switch | Fails closed, then recovers |
| 🤖👤 | Monthly reminder | Registered, sent, and on the phone (`-Accept reminder`) |
| 🤖 | First backup | Bundle collected, seed exported |
| 👤 | Bitwarden round trip | Hashes match |
| 👤 | Interrupted run, then run again (optional) | Finishes, or not run |
| 🤖 | Second run | Checkpoints 1 to 9 pass |

`-Accept vps-tests,reminder,lan-closed` answers all three at once. The checkpoint reads what the visits recorded and calls nothing.

---

# STAGE 11 · Log and clean up

> **Delivers:** no plaintext left on the PC, a record of the rebuild, and the list of what is left for a person
> **Where:** 🖥️
> **Module:** ✅ `windows\stages\11-cleanup.ps1`

It runs only after checkpoint 10, so the new bundle is already in Bitwarden and its round trip matched before the old one goes.

1. 🤖 **Delete the plaintext**, never by hand (C-31, C-44). It removes only what `state.json` records as plaintext: the bundle ZIP and the unpacked bundle, the VPS bootstrap, the download tokens, the OWUI API key file, and Stage 10's collector run folder and round-trip folder. Before each one, `Test-RecoveryPath` must confirm it is inside its root, and it must be the same object the controller recorded; links are never followed. The staging folder goes last, and only when nothing else is in it. Anything the controller did not create is named, never removed, and fails the stage until you have looked at it. `tools\Remove-RecoveryPlaintext.ps1` does the same on its own (without `-Execute` it lists what it would remove).
2. 🤖 **Record the rebuild** in `E:\recovery-state\rebuild-record.json`: the release commit and tag, the manifest hashes, the bundle it started from and the one Stage 10 made (file names and SHA-256), each stage's status, attempts and interruptions, the stages that took more than one attempt, and what step 1 removed. No secret and no address.
3. 🤖 **Scan the new seed** in `E:\recovery-state\owui-seed-new` with `tools\Test-NoSecrets.ps1`.
4. 👤 **What is left**, printed as steps:
   - **The ledger row.** An assistant writes every `AI-CHANGELOG.csv` row, so the stage prints the `Add-AIChange.ps1` command, filled in from the record, for Claude or ChatGPT to run. The ledger and `AI-CHANGELOG-PROTOCOL.md` are in neither the bundle nor the repo (R-21): copy them from the old PC or a backup first; the stage warns when they are missing.
   - **The new seed.** In `E:\recovery` (switch to `main` and pull) or another clone, replace `manifests\owui-seed\seed` with the files in `owui-seed-new`, run `./tools/Test-NoSecrets.ps1` and `Invoke-Pester ./tests`, then commit, push and tag the next release. From then on, a stage after Stage 1 runs again only once Stage 1 has run again and recorded the new commit. A seed the scan finds anything in is not offered.
   - **This guide.** Fix it wherever the rebuild went differently; the evidence for every attempt is in `E:\recovery-state\evidence\`.

Running it again is safe. Afterwards, Stages 1 to 7 need the bundle again (they read it, or need checkpoint 1, which checks it): to run one of them, download the bundle into `E:\recovery-secrets\` and start with `-Stage 1`.

🛑 **Checkpoint 11**

| Who | Check | Expected |
|---|---|---|
| 🤖 | Plaintext recorded in `state.json` | None |
| 🤖 | `E:\recovery-secrets\` | Gone, or empty when the controller did not create it |
| 🤖 | `rebuild-record.json` | Written, with the release commit |
| 👤 | Ledger row, seed commit, this guide | Done |

---

## Appendix A · Module index

| Module | Status | Stage |
|---|---|---|
| `Install-PowerShell7.cmd`, `Start-Recovery.cmd`, `Start-Recovery.ps1`, `tools\RecoveryMenu.psm1` | ✅ The recovery menu (replaces the planned `bootstrap\Install-Baseline.ps1`) | 1a to 3, and drives 1 to 11 |
| `Invoke-StackRecovery.ps1`, `tools\RecoveryState.psm1`, `tools\RecoveryHost.psm1` | ✅ Module 7 | all |
| `windows\stages\01-release.ps1` | ✅ Module 7 | 1 |
| `windows\stages\02-vps.ps1`, `linux\stages\02-bootstrap.sh`, `linux\stages\02-base.sh`, `tools\RecoveryVps.psm1` | ✅ Module 8 (replaces ♻️ `linux\step1.sh`) | 2 |
| `windows\stages\03-runtime.ps1` | ✅ Module 7 (C-12, C-13, C-14) | 3 |
| `windows\stages\04-render.ps1` | ✅ Module 7 | 4 |
| `tools\Restore-StackSecrets.ps1` | ✅ Module 5 | 1, 4, 7 |
| `tools\Test-RecoveryPath.ps1` | ✅ Shared path check (C-44, C-49) | all |
| `tools\Remove-RecoveryPlaintext.ps1` | ✅ Module 7. Owned-only clean-up, the same as Stage 11's own | 11 |
| `windows\stages\05-vps.ps1`, `linux\stages\05-place.sh`, `linux\stages\05-services.sh`, `linux\files\web-egress\` | ✅ Module 8 (R-13) | 5 |
| `windows\stages\06-fetch.ps1` | ✅ Module 7 | 6 |
| `tools\Export-OwuiSeed.py`, `tools\Import-OwuiSeed.py` | ✅ Modules 3 and 5. Run inside the OWUI container (C-39) | 7, 10 |
| `windows\stages\07-state.ps1` | ✅ Module 9 | 7 |
| `start-stack.ps1` | ♻️ (C-27; a live change waiting for Liam, which Stage 8 applies itself meanwhile) | 8 |
| `install-startup-task.ps1`, `install-mcpo-watchdog-task.ps1` | Not used: Stage 8 imports the live XML of both tasks | — |
| `windows\stages\08-serve.ps1` | ✅ Module 9 | 8 |
| `windows\stages\09-acceptance.ps1`, `linux\stages\09-reach.sh` | ✅ Module 9 | 9 |
| `windows\stages\10-rehearsal.ps1`, `linux\stages\10-vps.sh`, `linux\stages\10-killswitch.py`, `windows\reminder\` | ✅ Module 9 | 10 |
| `tools\Collect-StackSecrets.ps1` | ✅ Modules 2 and 4. Rewritten to the shared versioned map; SQLite backup API for ntfy (C-03 to C-10) | before recovery, and 10 |
| `windows\stages\11-cleanup.ps1` | ✅ Module 9 | 11 |
| `Add-AIChange.ps1` | ✅ The stack's own; Stage 11 prints its command for an assistant | 11 |
| `pullall.ps1` | Not used for recovery (C-17) | — |
| `kais_chat_tidy.ps1` | 🗄️ Retired (R-20). Never committed: it holds a dead hard-coded key | — |

## Appendix B · Manifests

| File | Holds | Source today |
|---|---|---|
| `topology.json` | The controller's folders, hosts, roots (and which Stage 1 creates), compose projects | Hand-kept (Module 7), checked against its schema |
| `endpoints.json` | Every templated file and its placeholders | `tools/Sync-StackFiles.ps1` (Appendix E) |
| `stack-files.json` | Which live files are copied into `stack\`, `extras\`, `vps\` and `windows\startup\` | Hand-kept; `tools/Sync-StackFiles.ps1` copies them |
| `windows-apps.json` | winget IDs and versions, the GPU driver | `tools/Sync-StackManifests.ps1` |
| `ollama-env.json` | Machine-scope profile | `tools/Sync-StackManifests.ps1` |
| `ollama-models.json`, `stack\modelfiles\` | Model names, tags, digests; custom models point at their Modelfile and base | `tools/Sync-StackManifests.ps1` (44 models, 6 custom) |
| `comfyui-requirements.lock`, `comfyui-nodes.json` | Python lock, package indexes, ComfyUI and custom-node commits | `tools/Sync-StackManifests.ps1` |
| `comfyui-weights.json` | Destination, bytes, SHA-256, URL, auth; `checked` when the URL was seen to serve that SHA-256 | `tools/Sync-StackManifests.ps1 -Only weights`; URLs set by hand are kept |
| `serve.json` | The seven Serve rules, no host names | `tools/Sync-StackManifests.ps1` |
| `tasks.json`, `windows\tasks\*.xml` | Scheduled tasks (XML with `{{USER_SID}}`, `{{USER_ID}}`, `{{USER_PROFILE}}`), startup items, the stack scripts they run, and what is retired or left out | `tools/Sync-StackManifests.ps1` |
| `images.json` | The image behind every PC and VPS container, its digests, and whether it is still stored | `tools/Sync-StackManifests.ps1` |
| `acceptance.json` | One test row per capability (C-46): a safe call or a 👤 step, and the stage a failure goes back to | Hand-kept (Module 9), checked against its schema and the seed schema's expected tools and functions |
| `owui-seed\schema.json` | Field allowlist: repo-safe, secret reference or excluded (C-41) | 🛠️ |
| `owui-seed\*.json` | Functional seed, with OWUI version, image digest and Alembic revision | 🛠️ `Export-OwuiSeed.py` |
| `owui-api-consumers.json` | Every file that holds the OWUI API key: only the gcal bridge's `.env` | Hand-kept (Module 9), from reading the stack's code |
| `secrets.json` | Required and optional secret rows (names and logical destinations, no values) | Stage 4b table |

## Appendix C · Register

| ID | Question | Status | Note |
|---|---|---|---|
| R-01 | Recovery repo name and layout | 🟡 Name decided | Private repo `ollama-cria` (Liam, 5 Oct). Layout in Appendix D still to be agreed |
| R-02 | Do the bootstrap scripts move into the repo? | 🟢 Direction agreed | Yes, refactored into stage modules |
| R-03 | Which bootstrap survives? | 🟢 Direction agreed | One controller; old entry points retired after acceptance |
| R-04 | Does `pullall.ps1` read the manifest? | 🟢 Direction agreed | No; replaced by the Stage 6 fetcher |
| R-05 | Pin ComfyUI and capture custom nodes | 🟢 Direction agreed | `bb131be9…`; node commits in `comfyui-nodes.json` |
| R-06 | Split the ComfyUI folder? | 🟢 Direction agreed | No split; classify in the manifest |
| R-07 | Pagefile and Phase 7 items | 🟢 Direction agreed | 32768–81920 MB on C:, set only if different |
| R-08 | ntfy users and tokens | 🟢 Direction agreed | `user.db` in bundle folder 07 |
| R-09 | Small volumes | 🟢 Direction agreed | Bolt keys required; mcpo runtime config regenerated (needs proof). Discord state dropped with the bridge (`AICL-0131`) |
| R-10 | How ComfyUI starts | ✅ Fact settled | Startup VBS; Stage 8d installs it |
| R-11 | ntfy watcher tasks | 🟢 Direction agreed | XML export with SID substitution |
| R-12 | `vps` alias target | ✅ Fact settled | Tailnet name; new host key checked against the console |
| R-13 | Locally built VPS images | 🟢 Built for the restore | Stage 5c builds both: Jina from the captured `jina-official\Dockerfile`, searxng-mcp from the new `linux\files\web-egress\searxng-mcp\Dockerfile` with a compose override. The live VPS still runs the bare image; moving it to the built one is Liam's call |
| R-14 | Kokoro placement | ✅ **Resolved** | VPS. Agreed by ChatGPT, Antigravity and Liam |
| R-15 | Endpoint contract | 🟢 Direction agreed | Appendix E |
| R-16 | `OLLAMA_KEEP_ALIVE`: live `45s` or documented `0`? | ✅ **Decided by Liam** | `45s` (5 Oct). Documents updated in `AICL-0127` |
| R-17 | OWUI seed boundary | 🟠 Revised in v0.3 | Table in 7d: user-settings projection, group members and full owner remap added; channel and webhook out. Notes and the memory entry stay out |
| R-18 | Ollama and Docker updater policy | ⏳ Open, Liam | Pins stop winget only (C-30) |
| R-19 | Discord bridge history | ✅ Moot | Bridge retired by Liam, 5 Oct (`AICL-0131`) |
| R-20 | Retire `OWUI-Automation-Chat-Tidy` and `kais_chat_tidy.ps1` | 🆕 🟢 Proposed | Fails daily with 401; OWUI has no automations left. Not rebuilt; script goes on the Phase 1 clean-up list |
| R-21 | Where are `AI-CHANGELOG.csv` and `AI-CHANGELOG-PROTOCOL.md` backed up? | ⏳ Open, Liam | Neither the bundle nor the repo carries them; Stage 11 warns when they are missing. In the bundle, the evidence check would treat every long ledger line as a secret, so that needs a change first |

An item moves to **Resolved** only when ChatGPT, Antigravity and Liam all agree.

## Appendix D · Proposed layout of `ollama-cria` (R-01)

```
ollama-cria/
├── Install-PowerShell7.cmd, Start-Recovery.cmd, Start-Recovery.ps1   the menu
├── Invoke-StackRecovery.ps1
├── windows/
│   ├── stages/        01-release … 11-cleanup
│   ├── reminder/      Send-BackupReminder.ps1, its task XML
│   ├── startup/       start_comfyui_hidden.vbs
│   └── tasks/         *.xml (SID placeholders)
├── linux/
│   ├── stages/        02-bootstrap.sh, 02-base.sh, 05-place.sh, 05-services.sh,
│   │                  09-reach.sh, 10-vps.sh, 10-killswitch.py
│   └── files/         web-egress/ restore-only: searxng-mcp/Dockerfile, compose.override.yml
├── stack/             → E:\ai\ollama (compose, Dockerfiles, bridges, relay, scripts;
│                      not discord-owui-bridge\ or kais_chat_tidy.ps1)
├── extras/dashboard/  → E:\ai\ag-startuip\cline-dashboard
├── vps/
│   ├── web-egress/    compose, gateway, guard, settings, jina-official
│   ├── kokoro/        compose.yml
│   ├── nginx/         groq-relay template
│   └── systemd/       docker.service.d/owui-web-egress.conf
├── manifests/         Appendix B
├── tools/             Collect-/Restore-StackSecrets.ps1, Test-RecoveryPath.ps1,
│                      Remove-RecoveryPlaintext.ps1, Export/Import-OwuiSeed.py
└── docs/              RESTORE.md, reviews/
```

> ⚠️ `.gitignore` today excludes `*secret*`, which would also exclude `Collect-StackSecrets.ps1` and `Restore-StackSecrets.ps1`. The repo's `.gitignore` allowlists those two by name and keeps a content scan in CI (C-33).

## Appendix E · Endpoint contract (R-15)

| Service | Host | Port | Reached at | Used by |
|---|---|---|---|---|
| Brave/Jina gateway | VPS | 13100 | `{{VPS_TS_IP}}` | `web-vps-relay` |
| Jina Reader | VPS | 13000 | `{{VPS_TS_IP}}` | relay |
| SearXNG | VPS | 18080 | `{{VPS_TS_IP}}` | relay |
| searxng-mcp | VPS | 13055 | `{{VPS_TS_IP}}` | mcpo |
| HTTP proxies | VPS | 8888, 8889 | `{{VPS_TS_IP}}` | relay, tools |
| Kokoro TTS | VPS | 8880 | `{{VPS_TS_IP}}` | OWUI `audio.tts.openai.api_base_url` |
| Groq STT relay | VPS | 18099 | `{{VPS_TS_IP}}` | OWUI STT base URL |
| `web-vps-relay` | PC | 13100, 3001, 8080 | Docker network | OWUI, tools |
| Bolt | PC | 3001 | `{{PC_TS_IP}}` | VPS |
| open-terminal | PC | 18019 | `{{PC_TS_IP}}` | VPS |
| Serve rules | PC | 443, 444, 2000, 8443, 9000; TCP 11434, 8188 | Tailnet | Phone, tablet, VPS |

Two kinds of placeholder never render to a real address. `{{STALE_TS_IP}}` marks a tailnet address that no node had at capture time, and `{{VPS_PUBLIC_IP}}` marks the VPS's own public address, which stays out of the repo. Both render as documentation addresses (`192.0.2.x`, `2001:db8::x`) that go nowhere. Today `{{VPS_PUBLIC_IP}}` appears only in comments (`guard.sh`, the Groq relay site, `owuihelp`). `tools/Sync-StackFiles.ps1` names every such line when it captures one, so a line that needs the real address can be fixed by hand.

The OWUI seed keeps such an address differently (Liam, 8 October 2026). A tailnet address or MagicDNS name in OWUI's data that matches neither node, such as the old address in `ntfy_push`'s code, moves to bundle folder 03 as `{{BUNDLE:embedded/address/<n>}}`. The capture names where it was in a warning, and Stage 7 puts it back unchanged.

## Appendix F · Traps

- 🗄️ **OWUI's `config` table overrides compose environment variables.** Check settings in Admin, not in `.env`.
- 🔑 **The OWUI API key:** on a working system, never regenerate it casually. On a clean deployment it is new by definition, so Stage 7 re-injects it everywhere.
- 🐍 **Two `python.exe` processes = one ComfyUI.** Don't kill the parent.
- 🌐 **Keep ComfyUI on `--listen 0.0.0.0`.** The containers reach it that way. Tailnet access goes through Serve.
- 🧱 **Windows may ask whether Python can use networks** when ComfyUI first starts. Don't allow it: Stage 8's firewall rule already lets in this PC and the tailnet, and an allow-all rule for Python opens ComfyUI to the LAN (C-52). If Windows makes Block rules for Python instead, Stage 8 names them in a warning; turn them off only if the tailnet cannot reach ComfyUI in Stage 9.
- 🐍 **`C:\Python313` is a fixed path.** The PowerShell tool's task and scripts name it, so Stage 3 installs Python 3.13 there, not in the per-user default.
- 🧮 **Machine scope only for `OLLAMA_*`.** A User-scope copy silently wins over the Machine one.
- 🗃️ **Never delete SQLite `-wal` files** to "clean up" a database. Committed data can live there. Capture with the backup API instead.
- 🧱 **SQLite on a Windows bind mount locks badly.** Every database lives in a named volume.
- 📏 **Exit codes lie.** Check contents, row counts and real responses.
- 🧷 **The guard needs Docker's drop-in too.** Without `docker.service.d/owui-web-egress.conf`, Docker starts even when the guard failed.
- 🔐 **Valves are encrypted with `WEBUI_SECRET_KEY`.** Copying rows between installs breaks them; go through OWUI's own codec.
- 🚫 **`kais_chat_tidy.ps1` has a hard-coded API key** (dead, but still a secret-shaped string). Never commit it; it is retired.

---

*Draft v0.6. Where this guide and the live machine disagree, the live machine is right.*
