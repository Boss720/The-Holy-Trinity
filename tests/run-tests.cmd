@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run-parallel.ps1" %*
exit /b %ERRORLEVEL%
