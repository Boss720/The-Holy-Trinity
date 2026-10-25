@echo off
rem Codex code review, forced read-only.
rem   codex-review.cmd                 review uncommitted changes
rem   codex-review.cmd --base main     review this branch against main
rem   codex-review.cmd --commit SHA    review one commit
setlocal
set "ARGS=%*"
if "%~1"=="" set "ARGS=--uncommitted"
call "%~dp0codex.cmd" review -c sandbox_mode=read-only %ARGS% <nul
exit /b %ERRORLEVEL%
