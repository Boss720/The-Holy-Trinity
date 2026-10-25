@echo off
rem One-shot read-only Codex question. Final answer also saved to .codex-out\codex-last.md
rem   cmd:        scripts\codex-ask.cmd "Why does test X fail? Point to file:line."
rem   Git Bash:   echo "Why does test X fail?" | ./scripts/codex-ask.cmd
rem   any shell:  scripts\codex-ask.cmd < prompt.txt
rem No argument = prompt read from stdin (avoids cmd quote-stripping on paths with spaces).
setlocal
if not exist "%~dp0..\.codex-out" mkdir "%~dp0..\.codex-out"
set "OPTS=exec --sandbox read-only --ephemeral --skip-git-repo-check -o .codex-out\codex-last.md"
if [%1]==[] (
  call "%~dp0codex.cmd" %OPTS% -
) else (
  call "%~dp0codex.cmd" %OPTS% %* <nul
)
exit /b %ERRORLEVEL%
