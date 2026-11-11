' Silent launcher for the Claude Win Env Audit GUI.
' Runs PowerShell with a hidden console so only the WPF window appears.
Dim shell, fso, baseDir, command
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
command = "powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & baseDir & "\app\ClaudeWinEnvAudit.Gui.ps1"""
shell.Run command, 0, False
