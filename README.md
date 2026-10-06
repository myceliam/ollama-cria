# 🦙 ollama-cria

**Disaster recovery for Liam's Open WebUI, Ollama and ComfyUI stack.** A *cria* is a baby llama: this repo grows a new copy of the stack from nothing.

> **Starting point:** two brand-new machines (a Windows 11 PC and an Ubuntu 24.04 VPS). Only GitHub, Bitwarden and Liam's accounts survive.
> **End point:** the same capabilities as today: models, tools, MCP servers, functions, skills, presets, settings, Serve rules and the VPS web egress. Chat history and old uploads are deliberately not restored.

| | |
|---|---|
| **The guide** | [`docs/RESTORE.md`](docs/RESTORE.md) (v0.3, ledger `AICL-0132`) |
| **Status** | 🚧 Being built module by module. Nothing here has been run against a real rebuild yet. |
| **Secrets** | **None in this repo, ever.** They travel in one bundle kept in Bitwarden. CI scans every file. |
| **Reviewers** | Claude builds; ChatGPT reviews adversarially; Antigravity checks on the PC; Liam signs off. |

---

## 🗺️ How a rebuild flows

```mermaid
flowchart TD
  S0[0 Basics via winget] --> S1[1 Release, manifests, secrets bundle]
  S1 --> S2[2 VPS base + tailnet]
  S1 --> S3[3 Windows runtime]
  S2 --> S4[4 Render endpoints + place secrets]
  S3 --> S4
  S4 --> S5[5 VPS guard, egress, Kokoro, STT]
  S4 --> S6[6 Models and weights]
  S5 --> S7[7 Images, volumes, OWUI seed]
  S6 --> S7
  S7 --> S8[8 Services, Serve, tasks]
  S8 --> S9[9 Functional tests]
  S9 --> S10[10 Reboot + rerun rehearsal]
  S10 --> S11[11 Log and clean up]
```

Every stage ends with a 🛑 checkpoint that must pass before the next one starts. The full detail is in [`docs/RESTORE.md`](docs/RESTORE.md).

---

## 🧱 Modules

Built in this order: the **capture side first**, because a restore script can be written on a new machine after a disaster, but the secrets bundle and the OWUI seed can only be made from the machine that still works.

| # | Module | What it does | Status |
|---|---|---|---|
| 1 | `tools/Test-RecoveryPath.ps1` | The one path check every stage uses before it writes, copies, extracts or deletes anything | 🔍 |
| 1 | `manifests/schemas/restore-map.schema.json`, `manifests/recovery-roots.json`, `tools/Test-RestoreMap.ps1` | The versioned restore-map format the collector writes and the restorer reads | 🔍 |
| 1 | `tools/Test-NoSecrets.ps1` | CI guard: refuses secret-shaped strings, private addresses and forbidden files | 🔍 |
| 2 | `manifests/secrets.json`, `manifests/bundle-folders.json` | The secret inventory (names and logical locations only, never values) and which root each bundle folder restores to | 🚧 |
| 2 | `tools/Collect-StackSecrets.ps1` | Rewritten collector: plans offline by default; with `-Execute` builds a protected bundle, its restore map and the ZIP | 🚧 |
| 3 | `tools/Export-OwuiSeed.py`, `manifests/owui-seed/schema.json` | OWUI functional seed exporter, run inside the OWUI container: one read-only snapshot, an allowlist where anything unknown stops the export, Valves decrypted with OWUI's own codec, secrets moved to references for bundle folder 03 | 🚧 |
| 4+ | Stage modules and the controller | `Invoke-StackRecovery.ps1` and `windows/stages/*`, `linux/stages/*` | ⏳ |

Status key: ✅ done and reviewed · 🔍 built, in review · 🚧 in progress · ⏳ not started.

---

## 🧪 Running the tests

Needs PowerShell 7.4+ and Pester 5.

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser   # once
Invoke-Pester ./tests -Output Detailed
./tools/Test-NoSecrets.ps1                                      # the same scan CI runs
python -m unittest discover -s tests/python -v                 # the seed exporter (Python 3.11, standard library only)
```

CI runs all three on Windows and Linux for every push and pull request. The collector's VPS tests use stand-ins for `ssh` and `scp` (`tests/fakes/`) and run on Linux only; its volume tests need a Linux Docker engine, so they run on the Linux runner and are skipped elsewhere. The seed exporter's tests use a stand-in for OWUI's Valve codec (`tests/python/fake_owui/`) and a fake OWUI 0.11.4 database built at run time.

---

## 🔒 Rules for everyone (people and assistants)

1. **No secret values** in code, tests, fixtures, docs, commit messages or logs. Tests build fake secrets at run time; they are never written into a file.
2. **No private addresses.** Tailnet IPs and hostnames are templated (`{{PC_TS_IP}}`, `{{VPS_TS_IP}}`).
3. **Nothing runs for real** against the live PC or VPS until Liam signs off the register in `docs/RESTORE.md` Appendix C.
4. **Every change is logged** in the stack's ledger (`AI-CHANGELOG.csv` on the PC) with its `AICL` id.
5. Where the guide and the live machine disagree, **the live machine is right**: fix the guide.
