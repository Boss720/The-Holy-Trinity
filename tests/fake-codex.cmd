@echo off
set "FAKE_CODEX_ARGUMENTS=%*"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fake-codex.ps1"
exit /b %ERRORLEVEL%
