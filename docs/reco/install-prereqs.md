# Prerequisite install commands (verified 2026-10-26 against official docs)

Copy these exactly. Anything marked UNVERIFIED must not appear in user-facing docs or scripts as a promise.
The commands are the same in cmd and PowerShell unless a column says otherwise.

| Tool | Role | Install | Where it lands | Login | Status check |
|---|---|---|---|---|---|
| Git for Windows | required (2.31+) | `winget install --id Git.Git -e --source winget --silent --accept-package-agreements --accept-source-agreements` (manual: https://git-scm.com/download/win) | `C:\Program Files\Git` (machine scope, UAC prompt); open a new terminal afterwards | none | `git --version` |
| Claude Code | required (orchestrator; desktop app or CLI) | PowerShell: `irm https://claude.ai/install.ps1 \| iex`. cmd: `powershell -NoProfile -ExecutionPolicy Bypass -c "irm https://claude.ai/install.ps1 \| iex"`. Winget alternative: `winget install Anthropic.ClaudeCode` (no auto-update). Docs: https://code.claude.com/docs/en/setup | `%USERPROFILE%\.local\bin\claude.exe` | `claude auth login` (opens a browser) | `claude auth status` (exit 0 = logged in) |
| Codex CLI | optional (needs a ChatGPT plan or API key) | `powershell -ExecutionPolicy ByPass -c "irm https://chatgpt.com/codex/install.ps1 \| iex"` (docs: https://github.com/openai/codex) | `%LOCALAPPDATA%\Programs\OpenAI\Codex\bin\codex.exe`; the script puts that folder on the User PATH | `codex login` (browser) or `codex login --device-auth` | `codex login status` (exit 0 = logged in) |
| Antigravity CLI `agy` | recommended (UI tasks, Codex fallback) | PowerShell: `irm https://antigravity.google/cli/install.ps1 \| iex`. cmd: `curl -fsSL https://antigravity.google/cli/install.cmd -o install.cmd && install.cmd && del install.cmd` (docs: https://antigravity.google/docs/install?tab=cli) | `%LOCALAPPDATA%\agy\bin\agy.exe` (PATH change not confirmed; trinity finds it at this path without PATH) | run `agy` once interactively (browser, Google account) | no status command; `agy --version` proves the install only |

## Facts and limits

- Claude Code `claude auth status` prints JSON and exits 0 when logged in, 1 when not.
- Codex: `codex login status` exits 0 when logged in; the logged-out exit code is undocumented (trinity already treats non-zero as not logged in).
- `agy` has no login-status command. trinity treats an installed `agy.exe` as available; a first `trinity dispatch antigravity` fails with an "authentication required" message until the user has run `agy` once.
- Never install or log in to Codex or Antigravity from a script on the user's behalf: both need the user's own account in a browser.
- UNVERIFIED (do not state in docs): winget package for Codex, the Node.js version floor for the Codex npm package, the Antigravity IDE terminal command (`antigravity-ide` is used by `trinity ui` but appears in no official doc; docs call the IDE a Start-menu app).
- Codex via `npm install -g @openai/codex` creates `codex.cmd`, which `Find-CodexExe` does not look for. Recommend only the official installer above.
- `trinity doctor` fix lines and INSTALL.md must use the commands in this table, nothing else.
