@echo off
if "%~1"=="" (
    echo Usage: claude-gateway ^<account^> [Claude Code arguments...] 1>&2
    exit /b 2
)
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File "%~dp0claude-gateway.ps1" %*
exit /b %errorlevel%
