# Instructions for assistants working in ollama-cria

Read `README.md` first, then `docs/RESTORE.md`.

- **Never write a secret value** anywhere in this repo: not in code, tests, fixtures, docs or commit messages. Tests create fake secrets at run time (for example `'sk-' + ('A' * 40)`), so no literal ever lands in a file.
- **Never add tailnet IPs, MagicDNS names or other private addresses.** Use `{{PC_TS_IP}}` and `{{VPS_TS_IP}}`.
- Run `Invoke-Pester ./tests` and `./tools/Test-NoSecrets.ps1` before pushing. CI runs both.
- Every path a script writes, copies, extracts or deletes goes through `tools/Test-RecoveryPath.ps1` first.
- Read-only against the live machines until Liam signs off. Log changes to the stack in `AI-CHANGELOG.csv` on the PC via `Add-AIChange.ps1`.
- Reviews and briefs for ChatGPT and Antigravity live on the PC in `E:\ai\ollama\docs\recovery\` (its `README.md` indexes them).
