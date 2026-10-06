# Windows PowerShell tool for Open WebUI

This is the Windows-side broker for the native Open WebUI tool `windows_powershell`.
The model sees one function. Before execution, Open WebUI shows the user a real popup
selection box with exactly three choices:

- `Read`
- `Read/Write`
- `Read/Write Elevated`

Closing the popup cancels the call. Background and sub-agent calls have no interactive
popup, so the tool refuses them.

## Security model

- The broker is a non-elevated scheduled task running as the signed-in Windows user.
- It binds only to the PC Tailscale address on port `18110`, never `0.0.0.0`.
- Requests require a dedicated bearer token stored in the stack `.env` and injected
  into Open WebUI; the value is never committed to source.
- `Read` parses the PowerShell AST, permits only read-oriented cmdlets/functions, blocks
  assignments, redirection, method calls, dynamic command names, scripts and native
  executables, and executes in Constrained Language mode.
- `Read/Write` runs arbitrary PowerShell with the normal non-elevated user token.
- `Read/Write Elevated` launches only that command through Windows `RunAs`; Windows UAC
  must be accepted for the call. It executes only if the model's function call also explicitly
  requested `read_write_elevated` and supplied the reason shown in the popup. Selecting Elevated
  on a lower-privilege request refuses the call and asks for a fresh explicit request. No elevated
  listener or permanently privileged task exists.
- Obvious secret-bearing environment-variable names are removed from child processes.
- One command runs at a time. Time, input and output are bounded. A local JSONL audit log
  records mode, reason, caller, command hash, a redacted preview and the result, not output.

The read policy is deliberately conservative, but it remains an application guardrail,
not a Windows security boundary. A PowerShell command approved under either write choice
has the corresponding user's real permissions and should be treated exactly like a local
terminal command.

## Files and operation

- `server.py` — authenticated host broker.
- `Validate-ReadCommand.ps1` — read-only AST policy.
- `Invoke-Elevated.ps1` / `Elevated-Runner.ps1` — one-call UAC path.
- `Install-WindowsPowerShellTool.ps1` — token creation and limited scheduled-task install.
- `Start-WindowsPowerShellTool.ps1` — optional manual launcher; the scheduled task runs
  `server.py` directly so stopping the task also stops the listener.
- `Test-WindowsPowerShellTool.ps1` — health/read/denial/non-elevated-write smoke tests.
- `config.json` — non-secret bind and limit settings.

Run the installer from PowerShell:

```powershell
& 'E:\ai\ollama\windows-powershell-tool\Install-WindowsPowerShellTool.ps1'
```

The elevated route is intentionally excluded from unattended smoke tests because testing it
would itself display UAC and require a human choice.
