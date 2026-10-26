# Install and release spec (v0.4.0)

Goal: anyone who downloads a GitHub **release** zip of trinity on a clean Windows 10/11 machine reaches a working
`trinity init <project>` + `trinity status` with no errors, or gets one exact command (or a Claude prompt) for each
missing prerequisite. This file is the contract for the workers. Do not edit files outside your scope.

## Facts about the current code (do not re-derive)

- A GitHub release zip has **no `.git`**. `scripts\trinity.ps1` now runs `help`, `version`, `doctor`, `init` without a repo;
  every other command needs the git repo of the current folder (`Get-RepoPaths` in `scripts\lib\board.ps1`).
- `trinity init <path>` copies the toolkit from the folder that holds the running script (`$kit`) into the target repo.
  So the release zip must contain every file in the `$toolkit` list in `scripts\trinity.ps1` (`init` section) and the docs it
  copies (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.agent\rules\holy-trinity.md`, `.claude\settings.json`).
- `trinity.cmd` -> `scripts\trinity.ps1` (PowerShell 5.1). `trinity.sh` is the Git Bash entry.
- `scripts\lib\board.ps1` has `Find-ClaudeExe`, `Find-CodexExe`, `Find-AgyExe`, `Get-AgentAvailability`, `Test-CliLogin`.
  Env overrides: `CLAUDE_EXE`, `CODEX_EXE`, `AGY_EXE`, `TRINITY_DISABLE` (comma list: codex, antigravity, claude).
- `git rev-parse --path-format=absolute` needs **git >= 2.31**.
- Runner commits (Codex/Antigravity branches) fail without `git config user.name` and `user.email`.
- Repo: `https://github.com/Boss720/The-Holy-Trinity`. Release asset names: `trinity-v<VERSION>.zip`, `trinity-v<VERSION>.zip.sha256`.
  The zip has one top-level folder `trinity-v<VERSION>\`. `VERSION` file at the toolkit root holds e.g. `0.4.0`.

## Hard rules for every PowerShell file you write

- Windows PowerShell **5.1** only. No `&&`, `??`, ternary, `-AsHashtable`, no PS7 features.
- Save as **UTF-8 with BOM, CRLF line endings, ASCII only** (no em-dashes, smart quotes). `.githooks\pre-commit` blocks commits otherwise.
- `.cmd` files: CRLF. No admin rights needed anywhere. Work from a folder whose path contains spaces. Work with no git repo around.
- Never write real keys or tokens into any file. Do not touch the Machine PATH or any system setting.
- Self-contained: do not edit `scripts\trinity.ps1`, `scripts\lib\board.ps1`, `tests\run-tests.ps1`, `README.md`, `CHANGELOG.md`, `AGENTS.md`, `CLAUDE.md`, `VERSION`.
- Verify before finishing: parse-check each .ps1 (`[System.Management.Automation.Language.Parser]::ParseFile`), then run it for real in a
  folder with spaces and show the output in your final message.

## Module A: installer + doctor (task `installer`)

Scope: `install.ps1`, `install.cmd`, `scripts\doctor.ps1` (new files only).

### scripts\doctor.ps1

Read-only. Params: `[switch]$Json`. Dot-source `lib\board.ps1` (relative to `$PSScriptRoot`) for the `Find-*` helpers; it must
work when the current folder is not a git repo. Prints one line per check:

```
[ OK ] git            2.54.0 (needs 2.31+)
[WARN] codex          not installed (optional: Codex tasks then go to Antigravity)
       fix: <exact command or URL>
[FAIL] git-identity   user.name / user.email not set
       fix: git config --global user.name "Your Name"
       fix: git config --global user.email "you@example.com"
[INFO] version        trinity 0.4.0 at C:\path\to\trinity
```

Final line: `doctor: <n> ok, <w> warnings, <f> failures`. Exit code 0 when there are no `[FAIL]`, else 1. With `-Json`: print one JSON object
`{ "version": "...", "root": "...", "checks": [ { "name", "status": "ok|warn|fail|info", "detail", "fix": [ ... ] } ], "ok": <int>, "warn": <int>, "fail": <int> }`
and nothing else on stdout.

Checks, in this order (`name` is the exact label):

| name | rule | status if bad |
|---|---|---|
| `windows` | Windows 10 or 11 (`[Environment]::OSVersion.Version.Major -ge 10`) | fail |
| `powershell` | `$PSVersionTable.PSVersion` >= 5.1 | fail |
| `git` | `git --version` works and is >= 2.31 | fail; fix `winget install --id Git.Git -e --source winget` plus `https://git-scm.com/download/win` |
| `git-identity` | `git config user.name` and `user.email` both non-empty | fail; two `git config --global` fix lines |
| `git-bash` | `bash.exe` next to git (`<git>\..\bin\bash.exe` or `usr\bin`) | info only (needed just for `trinity.sh`) |
| `claude` | `Find-ClaudeExe`; logged in via `Get-AgentAvailability` | warn; fixes from the table in "Agent install commands" below |
| `codex` | same for Codex | warn (optional) |
| `antigravity` | same for `agy` | warn |
| `workers` | at least one of codex / antigravity available (logged in) | warn: "no headless worker; `trinity dispatch` will not run" |
| `path` | `Get-Command trinity.cmd` resolves to this toolkit folder | warn; fix `install.cmd -AddToPath` (path of this toolkit) |
| `repo` | only when the current folder is inside a git repo: `core.hooksPath` is `.githooks`, `scripts\trinity.ps1` exists in it | warn; fix `trinity setup` or `trinity init <repo>` |
| `disk` | free space on the drive of the toolkit folder < 5 GB | warn |
| `version` | `VERSION` file next to `scripts\` | info |

Env `TRINITY_DOCTOR_SKIP_LOGIN=1` skips the slow login probes (treat an exe that exists as available, detail "login not checked").
The self-test uses it. Honor `CLAUDE_EXE`, `CODEX_EXE`, `AGY_EXE`, `TRINITY_DISABLE` through the board.ps1 helpers.

### install.ps1 (repo root, next to `trinity.cmd`) and install.cmd

`install.cmd` = `@echo off`, `powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*`, `exit /b %ERRORLEVEL%`.

Params: `-Check` (run doctor only, change nothing), `-InstallGit`, `-InstallClaude`, `-AddToPath`, `-RemoveFromPath`, `-Init <path>`,
`-Yes` (no confirmation prompts), `-Help`. Unknown flag: print usage, exit 2.

Default run (no flags): banner `trinity <VERSION> installer`; `Unblock-File` every file under the toolkit folder (ignore errors; the zip
carries Mark-of-the-Web); run `scripts\doctor.ps1`; then print "Next steps" with the exact commands for what is missing and
`trinity init <your-project-folder>`. Never changes anything else.

- `-InstallGit`: if git is missing or older than 2.31 and `winget` exists, confirm (skip with `-Yes`) and run
  `winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements`; afterwards rebuild
  `$env:Path` from the Machine + User values so git is found in this same process; re-run the git check. No winget: print the
  download URL and stop with exit 1. Never run it when git is already fine.
- `-InstallClaude`: only the official Claude Code installer from the "Agent install commands" table, and only after confirmation (skip with `-Yes`).
  Do not run any login command; tell the user to run it (it opens a browser).
- Codex and Antigravity are never installed automatically (paid plan / Google account). doctor prints their fix lines.
- `-AddToPath`: append the toolkit folder to the **User** PATH (`[Environment]::SetEnvironmentVariable('Path', ..., 'User')`), only if absent
  (case-insensitive, ignore trailing `\`), also update `$env:Path` of this process, say "open a new terminal". `-RemoveFromPath` undoes it.
- `-Init <path>`: after the checks, run `scripts\trinity.ps1 init <path>` (path may contain spaces) and print its output. Refuse (exit 1) if doctor has a `[FAIL]`.
- Exit codes: 0 no failures, 1 failures or a step failed, 2 usage error.
- Must be re-runnable (idempotent). Must print what it changed and what it left alone.

## Module B: release packaging + GitHub Actions (task `release-pack`)

Scope: `scripts\build-release.ps1`, `.github\workflows\ci.yml`, `.github\workflows\release.yml` (new files only).

### scripts\build-release.ps1

Params: `-OutDir <dir>` (default `dist` under the repo root), `-Verify` (smoke test the built zip), `-Version <x.y.z>` (default: contents of `VERSION`).
Run from a git checkout of this repo (use the script's own folder to find the repo root; do not need git for the staging itself).

1. Stage an allowlist (exact paths, relative to repo root; fail with the missing path if one does not exist):
   `VERSION`, `README.md`, `INSTALL.md`, `CHANGELOG.md`, `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `trinity.cmd`, `trinity.sh`, `install.cmd`, `install.ps1`,
   `.agent\rules\holy-trinity.md`, `.claude\settings.json`, `.claude\agents\*.md`, `.claude\skills\army\SKILL.md`, `.githooks\pre-commit`,
   `scripts\agent-task.ps1`, `scripts\codex.cmd`, `scripts\codex-ask.cmd`, `scripts\codex-review.cmd`, `scripts\dashboard.ps1`, `scripts\dashboard.html`,
   `scripts\doctor.ps1`, `scripts\trinity.ps1`, `scripts\lib\board.ps1`, `docs\dashboard.md`, `docs\claude-install-prompt.md`, `tests\*` (recursive).
   Everything else (PLAN.md, HANDOFF.md, docs\reco, docs\failure-log.md, dashboard-sample.json, `.codex-out`, `.git`) stays out.
2. Zip to `<OutDir>\trinity-v<Version>.zip` with one top-level folder `trinity-v<Version>\`. **Do not use `Compress-Archive`** (PS 5.1 writes
   backslash entry names). Use `System.IO.Compression.ZipArchive` and write entry names with `/`. Keep the original bytes (no re-encoding).
3. Write `<OutDir>\trinity-v<Version>.zip.sha256` as `<lowercase hex>  trinity-v<Version>.zip` (two spaces; `certutil -hashfile` and `sha256sum -c` friendly).
4. Write `<OutDir>\RELEASE_NOTES.md`: the body of the `## v<Version>` section of `CHANGELOG.md`, else the `## Unreleased` body, else a one-line fallback; then a
   fixed footer with the install line: `Download trinity-v<Version>.zip, extract it, run install.cmd. See INSTALL.md.`
5. Lint the staged tree and fail loudly on: a `.ps1` without BOM / with non-ASCII after the BOM / without CRLF; a `.cmd` without CRLF; `.githooks\pre-commit`
   or `trinity.sh` with CRLF; any file containing `C:\Users\` or `D:\AI` (path leaks); any 1 MB+ file.
6. `-Verify`: extract the zip into `%TEMP%\trinity-release-verify-<guid>\folder with spaces\`, then check: all allowlisted files exist; create a throwaway git repo
   (`git init -b main`, set `user.name`/`user.email` locally, one commit); from the **extracted copy**, run
   `trinity.cmd version` (output `trinity <Version>`), `trinity.cmd help` (exit 0), `install.cmd -Check` (must not throw or print PowerShell parse errors; exit 0 or 1 both fine),
   `trinity.cmd init <throwaway repo>` (exit 0), then inside the throwaway repo `scripts\trinity.ps1 status` (exit 0) and `scripts\trinity.ps1 version`.
   Print `verify: PASS` or `verify: FAIL <step>` and exit 0 / 1. Always delete the temp folder.
7. Print the three output paths and the sha256. Exit non-zero on any failure.

### Workflows

- `ci.yml`: `on: push` (branches: main) and `pull_request`; job on `windows-latest`: `actions/checkout@v4`, set a git identity
  (`git config --global user.name "ci"` / `user.email "ci@example.invalid"`), run `tests\run-tests.cmd`. `permissions: contents: read`.
- `release.yml`: `on: push: tags: ['v*']` and `workflow_dispatch` (dry run: build + upload workflow artifact, no release). Job on `windows-latest`,
  `permissions: contents: write`: checkout, git identity, run tests, fail if the tag name is not `v` + contents of `VERSION`, run
  `powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-release.ps1 -OutDir dist -Verify` (default `shell: powershell` = PS 5.1, the same as users),
  then on tag push `gh release create "$env:GITHUB_REF_NAME" dist\trinity-v*.zip dist\trinity-v*.zip.sha256 --title "$env:GITHUB_REF_NAME" --notes-file dist\RELEASE_NOTES.md`
  with `GH_TOKEN: ${{ github.token }}`. Pin actions to a major version tag. Never use a personal token.
- Neither workflow can be run locally. Validate YAML structure by careful reading; say in your final message that the first Actions run is unverified.

## Module C: install docs (task `install-docs`)

Scope: `INSTALL.md` (repo root), `docs\claude-install-prompt.md`.

### INSTALL.md (audience: a Windows user who just downloaded the release zip; plain, short, command-first)

1. **What you need**: table `Tool | Required? | Why | How to get it`. Git for Windows (required, 2.31+), Claude Code (required: desktop app or CLI, it is the
   orchestrator), Antigravity CLI `agy` (needed for UI tasks and as Codex fallback), Codex (optional, needs a ChatGPT plan), Windows PowerShell 5.1 (built in).
   At least one of Codex / Antigravity is needed to `trinity dispatch`. Use only the commands in "Agent install commands" below.
2. **Install**: download `trinity-vX.Y.Z.zip` from the Releases page, optional hash check (`certutil -hashfile trinity-vX.Y.Z.zip SHA256`, compare with the `.sha256` asset),
   extract to a short path without OneDrive (example `C:\tools\trinity` or `%LOCALAPPDATA%\Programs\trinity`), run `install.cmd` (explain each flag in one line),
   open a new terminal, run `trinity doctor`.
3. **Use it in a project**: `trinity init <path to your git repo>`, fill "Project commands" in that repo's `AGENTS.md`, commit, open Claude Code there, `trinity status`.
4. **Let Claude do the install**: point to `docs\claude-install-prompt.md` and show how to use it (paste into Claude Code).
5. **Troubleshooting** table (symptom, cause, fix): "running scripts is disabled" / blocked file (right-click zip > Properties > Unblock, or `install.cmd` does it);
   `trinity is not recognized` (new terminal, or `install.cmd -AddToPath`, or use full path); `not inside a git repo`; `Please tell me who you are` (git identity);
   `codex not logged in` / `agy` not found (`trinity doctor` fix lines); Windows SmartScreen on first run; `'D:\...\x' is not recognized` from Git Bash (use `./trinity.sh`);
   dashboard port 7777 busy (`trinity dashboard -Port 7788`); path too long (extract closer to the drive root; `git config --global core.longpaths true`);
   `winget` missing (App Installer from the Microsoft Store, or download Git by hand).
6. **Update / uninstall**: download the new zip, extract, rerun `trinity init <project>` per project (toolkit files refresh, project docs are kept);
   `install.cmd -RemoveFromPath` and delete the folder to uninstall.

### docs\claude-install-prompt.md

A short intro, then ONE fenced text block the user pastes into a Claude Code session. The prompt makes Claude do the whole install and is written as instructions to Claude:
find the newest release via `https://api.github.com/repos/Boss720/The-Holy-Trinity/releases/latest` (read `assets[].browser_download_url` for the zip and the `.sha256`),
download both to a temp folder, verify the SHA-256 and stop on mismatch, extract to `%LOCALAPPDATA%\Programs\trinity`, run `install.cmd -InstallGit -AddToPath -Yes`
(after showing the command), read the doctor report, fix each `[FAIL]` and `[WARN]` using the exact fix lines (ask before installing Claude/Codex/Antigravity; **never** run
login commands, tell the user to run them), ask which project folder to set up, run `trinity init <folder>`, then `trinity doctor` and `trinity status` in it and
report results with evidence. Rules inside the prompt: show each command before running it, one command at a time, no admin elevation, do not change execution policy,
do not edit files outside the toolkit folder and the chosen project, stop and report on any unexpected error with the exact message. Add a second short prompt for
"update to the newest release". Windows cmd syntax for commands the user may copy.

## Agent install commands

SEE `docs/reco/install-prereqs.md` (verified against official docs; copy the commands from there exactly, do not invent others).
