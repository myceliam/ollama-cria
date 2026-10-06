' run-hidden.vbs - launch a PowerShell script with NO console window at all.
'
' Why this exists (2026-08-01):
'   pwsh.exe is a console application. When Task Scheduler starts it, Windows
'   allocates a conhost.exe FIRST, and only then does PowerShell get around to
'   parsing -WindowStyle Hidden. The window is already on screen by that point,
'   so you get a black flash every time the task ticks. Verified by watching
'   process creation: every task run produced a pwsh.exe parented to svchost.exe
'   with its own conhost.exe alongside it.
'
'   wscript.exe is a WINDOWS-subsystem binary, not a console one. Launching via
'   WshShell.Run with intWindowStyle = 0 creates the process hidden from the
'   outset, so no console is ever shown.
'
' Usage:
'   wscript.exe "E:\ai\ollama\run-hidden.vbs" "E:\path\to\script.ps1"
'   wscript.exe "E:\ai\ollama\run-hidden.vbs" "E:\path\to\script.ps1" "-Arg val"
'
' Notes:
'   - bWaitOnReturn is False, so this returns immediately. Task Scheduler will
'     mark the task complete straight away rather than waiting for the script.
'     Set it True if you need the task's Last Result to reflect the script.

Option Explicit

Dim sh, scriptPath, extraArgs, exe, cmd

If WScript.Arguments.Count < 1 Then
    WScript.Quit 2
End If

scriptPath = WScript.Arguments(0)

extraArgs = ""
If WScript.Arguments.Count > 1 Then
    extraArgs = " " & WScript.Arguments(1)
End If

' Prefer PowerShell 7; fall back to Windows PowerShell if it is not installed.
exe = "C:\Program Files\PowerShell\7\pwsh.exe"
Dim fso
Set fso = CreateObject("Scripting.FileSystemObject")
If Not fso.FileExists(exe) Then
    exe = "powershell.exe"
End If

cmd = """" & exe & """ -NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """" & extraArgs

Set sh = CreateObject("WScript.Shell")
' 0 = hidden, False = do not wait
sh.Run cmd, 0, False
