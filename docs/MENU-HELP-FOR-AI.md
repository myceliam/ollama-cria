# 🧑‍🔧 Helping Liam with the recovery menu

**For:** the assistant (Claude, ChatGPT or Antigravity) Liam asks for help while he rebuilds his PC with the recovery menu.
**Read next, only if you need them:** [`FULL-REBUILD-HUMAN.md`](FULL-REBUILD-HUMAN.md) (Liam's walkthrough, numbered like the menu), [`RESTORE.md`](RESTORE.md) (what each stage does and checks), [`START-HERE.md`](START-HERE.md) (what survived and where).

**Liam drives the menu himself.** He double-clicks `Start-Recovery.cmd`, types a step, and the menu runs the PowerShell for him, asking before every change. You are the help desk: read where he is, explain what the menu said, and tell him what to do next. You change nothing unless he asks you to.

---

## 1. 🧭 Ground rules

1. **Never ask for, print, paste or log a secret value.** The bundle's SHA-256, file names, sizes, paths and fingerprints are fine. Passwords, tokens, API keys and the files in `E:\recovery-secrets\` are not: if he pastes one, tell him to change it.
2. **Read-only by default.** Don't run the menu or `Invoke-StackRecovery.ps1 -Execute` yourself unless Liam asks. Never delete `E:\recovery-state\state.lock`: a second run while one is going is exactly what it stops.
3. **Don't edit the records by hand** (`menu.json`, `state.json`). The menu has a key for every fix: `b` goes back a step, `r` starts the menu over, a step number runs that step again.
4. **The VPS is his call.** Never choose *rebuild* for him and never type `REBUILD`: it wipes the server.
5. **Short, numbered steps, one question at a time,** and say what each step is for.

---

## 2. 🔎 See where he is

Either he pressed **`a`** in the menu (a note is on his clipboard and in `E:\recovery-state\help-note.txt`), or you run the read-only status yourself:

```powershell
pwsh -NoProfile -File E:\recovery\Start-Recovery.ps1 -Status
```

It prints every step with its mark, the details of each step that is not done or has skips, and the end of the log. It changes nothing and creates nothing.

| Mark (`-Status`) | Mark (menu) | Means |
|---|---|---|
| `[x]` | ✅ | Done |
| `[!]` | ❌ | Failed: the details say why |
| `[?]` | ✋ | Waiting for Liam: a stage asked something |
| `[r]` | 🔁 | Restart the PC, then choose the step again |
| `[-]` | ⏩ | Skipped (optional tasks only, with his reason) |
| `[ ]` | `[  ]` | Not done |
| `>` | ▶ | The next step: what Enter runs |

| Record | In `E:\recovery-state\` | Holds |
|---|---|---|
| The menu's record | `menu.json` | Steps 1a to 3: status, tasks he confirmed, skips and their reasons; his answers (`bundleSha256`, `bundleName`, `bundleBytes`, `vps` = `keep` or `rebuild`). No secrets |
| The log | `menu-log.txt` | Every check, answer and stage run, with times. Never a typed value |
| The controller's record | `state.json` | Stages 1 to 11: status, attempts, answers, and everything the controller created |
| Stage reports | `evidence\stage-NN-attempt-N.txt` | The full report of each stage run: every `CHECK`, `PROBLEM` and `ASK` line |
| The last help note | `help-note.txt` | What `a` copied |

The folder is `controller.stateRoot` in `manifests\topology.json`. Older records set aside by `r` are `menu-<time>.json` and `state-<time>.json`.

---

## 3. 🗺️ The steps

Steps 1a to 3 are the menu's own checks. Steps 4 to 14 run the controller's Stages 1 to 11 (step = stage + 3).

| Step | What | Done when | Common snags |
|---|---|---|---|
| **1a** | GitHub Desktop, sign in, this repo | `E:\recovery` is a clone of `myceliam/ollama-cria` on `main` with no local changes | Cloned into `Documents\GitHub` (move it, or clone again into `E:\recovery`); a branch other than `main`; local changes (GitHub Desktop: Changes, then Discard all) |
| **1b** | Board drivers, Windows Update, drives, Windows settings | Windows 11, nothing left in Windows Update, no restart pending, PowerShell 7.4+, winget, `E:` ready, NTFS and BitLocker on, nothing old in the stack's folders | The AMD chipset driver missing (the menu opens AMD's page for the chipset in the board's name, from WMI, in Edge: AMD's package is newer than the board maker's copy and carries the PSP driver; Intel's Management Engine advice does not apply); LAN, Wi-Fi, Bluetooth and audio from the board's ASUS page; new drives tested with CrystalDiskInfo and CrystalDiskMark before striping (stripe only two healthy drives with close SEQ1M results); the optional policy that keeps drivers out of Windows Update (undo: gpedit, set it back to Not Configured); `E:` new or wiped (Disk Management: GPT, New Simple Volume, NTFS, letter E); `E:` locked after the reinstall (unlock with its BitLocker recovery key); old stack folders (the menu renames them `<name>-before-rebuild-<date>`); `D:` is optional (Storage Spaces, see FULL-REBUILD-HUMAN) |
| **2** | Apps, the GPU driver, Tailscale, sign-ins | Git, Tailscale and Bitwarden installed; Tailscale connected and this PC named `pc`; signed in to Bitwarden | The node came up as `pc-1` (remove the old `pc` in the admin console, then rename); a pinned version fails (the menu offers the newest); ChatGPT comes from the Store (`msstore`); the NVIDIA driver is a manual download |
| **3** | The secrets bundle | One `stack-secrets-*.zip` in `E:\recovery-secrets\`, its SHA-256 matching Bitwarden, the full bundle inside (restore map plus folder `03`) | Saved to Downloads (move it and delete that copy); unzipped by Windows (delete the folder: **the menu never unzips, Stage 1 does**, into a protected folder); the key safety copy instead of the full bundle (START-HERE 5B); a folder left by the old Windows account (rename it in Explorer: the menu cannot rename at a drive root) |
| **4** | Stage 1: repo, protected folder, keys | Checkpoint 1 | The SHA-256 differs (download again); BitLocker off; the repo moved since (run step 4 again) |
| **5** | Stage 2: the VPS | Checkpoint 2 | The menu first asks **keep or rebuild**. Keep checks the VPS offers the host key filed in his backup; a mismatch stops everything (ask Liam what happened to the VPS). Rebuild needs the IONOS console and the fingerprint it prints |
| **6** | Stage 3: Windows runtime | Checkpoint 3 | Runs in an admin window (one UAC prompt, as Liam); restarts for WSL and Docker; SVM off in the BIOS |
| **7** | Stage 4: settings files and keys | Checkpoint 4 | A file from before is in the way (rename it `.old`) |
| **8** | Stage 5: the VPS side | Checkpoint 5 | On a kept VPS, a file that differs from the rendered one is refused: compare, then rename it `.old` on the VPS. The VPN never healthy: `VPS-REBUILD-AI.md` V9 |
| **9** | Stage 6: models and weights | Checkpoint 6 | Download tokens (Liam puts them in the file the ASK names); a model tag that moved |
| **10** | Stage 7: images, volumes, OWUI | Checkpoint 7 | The admin account and the API key file are Liam's; OWUI refused the key (make a new one) |
| **11** | Stage 8: the stack starts | Checkpoint 8 | Admin window again; the phone check |
| **12** | Stage 9: proof it works | Checkpoint 9 | Nine checks Liam does in OWUI and on his phone |
| **13** | Stage 10: restarts, outside tests, backup | Checkpoint 10 | Runs several times; the new bundle goes to Bitwarden |
| **14** | Stage 11: tidy up | Checkpoint 11 | Anything the controller did not make is named, never deleted |

---

## 4. 📜 Reading a stage report

The menu prints the controller's lines and colours them. Each line starts with one of these:

| Line | Means | What the menu does |
|---|---|---|
| `CHECK ok` / `CHECK FAIL` | One checkpoint row passed or failed | A failure stops the stage |
| `PROBLEM` | What went wrong, usually with what to do | Shows its hints and offers `r` (run again), `e` (open the full report), `a` (help note), `go<step>` (the step that fixes it) |
| `ASK [id] text` | Liam must do something, then accept | After he does it, `y` answers `-Accept <id>` and runs the stage again |
| `ASK text` (no id) | Liam must do something; there is nothing to accept | He does it, then runs the stage again |
| `WARN` | Worth reading; nothing stopped | Nothing |
| `Result:` | `done`, `failed`, `needs-user` or `reboot` | Marks the step |

Problems the menu recognises and points at a step for:

| Text in the report | Cause | Fix |
|---|---|---|
| `the repo is at X, not Y as Stage 1 checked` or `manifests/... changed since Stage 1` | The repo was pulled or switched after Stage 1 | Step 4 again, then this step |
| `Stage N's checkpoint no longer passes` | Something an earlier stage set up has changed | Step N+3 again; it only redoes what is missing |
| `needs Stage N first` | Out of order | Step N+3 |
| `holds the lock` | Another run is going, usually the admin window of Stage 3 or 8 | Let it finish or close it |
| `move it away` / `a different file is already there` | A file from before is where the controller wants to write | Rename the named file (add `.old`) after checking what it is |
| `BitLocker is not on` | BitLocker is off for `E:` | Step 1b |
| `changed or new files` | Local changes in the repo | GitHub Desktop: Changes, then Discard all |
| `elevated window could not start` | The UAC prompt was declined | Run again and click Yes |

For anything else, read the `PROBLEM` and `CHECK FAIL` lines, then the stage's section in `RESTORE.md`: every checkpoint row there says what it checks.

---

## 5. 🧯 When the menu itself goes wrong

| Symptom | What to do |
|---|---|
| "PowerShell 7 is not installed" | Run `Install-PowerShell7.cmd` first, then `Start-Recovery.cmd` |
| "This window runs as Administrator" | Close it and double-click `Start-Recovery.cmd` normally. Only Stages 3 and 8 need admin, and they open their own window |
| "Step X hit an error the menu did not expect" | The error is in `menu-log.txt`. The step is saved as it was; choose it again. If it repeats, ask Liam for the log lines and read the function the message names in `tools\RecoveryMenu.psm1` |
| "... is not a menu record this version can read; started a new record." | The menu set `menu.json` aside as `menu-unreadable-<time>.json` and started a new one. The stages' ticks come from `state.json`, so only steps 1a to 3 need checking again |
| The menu did not reopen after a restart | Double-click `Start-Recovery.cmd`; it carries on. (It sets a one-time RunOnce entry before each restart it offers.) |
| The menu cannot be used at all | The controller still works on its own: `pwsh -File E:\recovery\Invoke-StackRecovery.ps1` plans (changes nothing), and RESTORE.md's **The controller** section has every command. Steps 1a to 3 are then by hand: FULL-REBUILD-HUMAN.md lists each check |

If you think the menu has a bug, say so plainly, give the file and line, and suggest the fix. Liam decides whether you change the repo; any change goes through a pull request with tests (`Invoke-Pester ./tests`).

---

## 6. 🚪 Not the menu's job

- **Only the VPS is lost:** [`VPS-REBUILD-AI.md`](VPS-REBUILD-AI.md), from the surviving PC.
- **Only the key safety copy survived** (no folder `03` in the ZIP): [`START-HERE.md`](START-HERE.md) section 5B, by hand.
