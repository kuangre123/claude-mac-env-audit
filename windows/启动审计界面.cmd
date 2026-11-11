@echo off
chcp 65001 >nul
start "" powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0app\ClaudeWinEnvAudit.Gui.ps1"
exit /b
