# Installing Trinity

Trinity coordinates Claude Code, Codex, and Antigravity in a shared repository workspace. This guide explains how to install Trinity on Windows 10 or Windows 11.

## What you need

| Tool | Required? | Why | How to get it |
|---|---|---|---|
| Git for Windows (2.31+) | Required | Worktrees, branches, and commit hooks | Run the winget command below or download from https://git-scm.com/download/win |
| Claude Code | Required | Orchestrator: plans work, coordinates agents, and merges | Run the install command below or see https://code.claude.com/docs/en/setup |
| Antigravity CLI (`agy`) | Recommended | Headless UI worker and fallback when Codex is unavailable | Run the install command below (see https://antigravity.google/docs/install?tab=cli) |
| Codex CLI | Optional | Headless coding worker and code reviewer (requires ChatGPT plan) | Run the install command below (see https://github.com/openai/codex) |
| Windows PowerShell 5.1 | Required | Runs Trinity automation scripts | Built into Windows 10 and Windows 11 |

At least one worker agent (Codex or Antigravity) is required to use `trinity dispatch`.

### Prerequisite install commands

Install Git for Windows:
```bat
winget install --id Git.Git -e --source winget --silent --accept-package-agreements --accept-source-agreements
```

Install Claude Code from Command Prompt:
```bat
powershell -NoProfile -ExecutionPolicy Bypass -c "irm https://claude.ai/install.ps1 | iex"
```

Install Claude Code from PowerShell:
```powershell
irm https://claude.ai/install.ps1 | iex
```

Alternative Claude Code install via winget:
```bat
winget install Anthropic.ClaudeCode
```

Install Antigravity CLI `agy` from Command Prompt:
```bat
curl -fsSL https://antigravity.google/cli/install.cmd -o install.cmd && install.cmd && del install.cmd
```

Install Antigravity CLI `agy` from PowerShell:
```powershell
irm https://antigravity.google/cli/install.ps1 | iex
```

Install Codex CLI:
```bat
powershell -ExecutionPolicy ByPass -c "irm https://chatgpt.com/codex/install.ps1 | iex"
```

### Agent authentication commands

Log in to Claude Code:
```bat
claude auth login
```

Check Claude Code login status:
```bat
claude auth status
```

Log in to Codex:
```bat
codex login
```

Log in to Codex with device authorization:
```bat
codex login --device-auth
```

Check Codex login status:
```bat
codex login status
```

Authenticate Antigravity CLI:
```bat
agy
```

Check Antigravity CLI installation:
```bat
agy --version
```

## Install

Download the release zip `trinity-vX.Y.Z.zip` and the checksum `trinity-vX.Y.Z.zip.sha256` from https://github.com/Boss720/The-Holy-Trinity/releases.

Verify the download checksum:
```bat
certutil -hashfile trinity-vX.Y.Z.zip SHA256
```

Compare the output hash with the hash in `trinity-vX.Y.Z.zip.sha256`.

Extract the zip archive to a short path without OneDrive synchronization. Recommended locations:
- `C:\tools\trinity`
- `%LOCALAPPDATA%\Programs\trinity`

Open Command Prompt in the extracted folder and run the installer:
```bat
install.cmd
```

### Installer flags

The installer supports the following flags:

- `-Check`: Run prerequisite checks only and make no changes.
- `-InstallGit`: Install Git for Windows via winget if missing or older than 2.31.
- `-InstallClaude`: Install Claude Code using the official installer.
- `-AddToPath`: Add the toolkit folder to the User PATH environment variable. Existing `%VAR%` entries are kept as they are, and the previous value is saved to `%USERPROFILE%\.trinity\user-path-backup.txt`.
- `-RemoveFromPath`: Remove the toolkit folder from the User PATH environment variable.
- `-Init <path>`: Initialize Trinity in the target git repository if checks pass.
- `-Yes`: Run without interactive confirmation prompts.
- `-Help`: Show installer usage and options.

Run checks only:
```bat
install.cmd -Check
```

Automated install with Git and PATH setup:
```bat
install.cmd -InstallGit -AddToPath -Yes
```

Open a new terminal to reload environment variables. Verify the setup:
```bat
trinity doctor
```

Output machine-readable JSON:
```bat
trinity doctor -Json
```

## Use it in a project

Initialize Trinity inside an existing git repository:
```bat
trinity init D:\path\to\your-project
```

Edit the "Project commands" section in the target repository's `AGENTS.md`:
- Set `Test:` to your project test command.
- Set `Shared files:` to files only the orchestrator edits (such as package manifests).

Commit the configuration in the target repository:
```bat
git commit -am "Configure trinity project commands"
```

Open Claude Code in the target repository:
```bat
claude
```

Check agent availability and repository status:
```bat
trinity status
```

## Let Claude do the install

You can let Claude Code perform the complete setup automatically. See [docs/claude-install-prompt.md](docs/claude-install-prompt.md).

Open Claude Code and paste the installation prompt from that file. Claude will download the release, verify checksums, run `install.cmd`, configure PATH, resolve doctor warnings, and run `trinity init` in your project.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| "running scripts is disabled" or blocked file | Windows Mark-of-the-Web or execution policy restriction | Right-click the zip, open Properties, check Unblock, and click OK. `install.cmd` unblocks files automatically. |
| `trinity is not recognized` | Toolkit directory is not on PATH, or terminal was opened before PATH change | Open a new terminal. If missing, run `install.cmd -AddToPath` or use the full path to `trinity.cmd`. |
| `not inside a git repo` | Running a git-dependent Trinity command outside a git checkout | Change directory to a git repository initialized with `trinity init`, or run `git init`. `help`, `version`, `doctor`, and `init` work outside a repository. |
| `Please tell me who you are` | Git identity is not set | Configure your git user name and email using `git config --global`. |
| `codex not logged in` | Codex CLI is installed but not authenticated | Run `codex login`. If you do not have a ChatGPT plan, set `TRINITY_DISABLE=codex` to route tasks to Antigravity. |
| `agy` not found or authentication required | Antigravity CLI is not installed or has not run interactively | Install `agy` and run `agy` once interactively to complete browser login. |
| Windows SmartScreen prompt on first run | Windows Defender SmartScreen warns on unrecognized downloaded scripts | Click "More info", then click "Run anyway". |
| `'D:\...\x' is not recognized` from Git Bash | Running `trinity.cmd` from Git Bash with spaces in paths | Run `./trinity.sh` instead of `trinity.cmd` inside Git Bash. |
| Dashboard port 7777 busy | Another process is using port 7777 | Start the dashboard on another port with `trinity dashboard -Port 7788`, or stop the active instance with `trinity dashboard -Stop`. |
| Path too long error | Windows 260-character path limit exceeded | Extract Trinity closer to the drive root (such as `C:\tools\trinity`) and enable long paths in Git. |
| `winget` missing | Windows App Installer is not installed | Install App Installer from the Microsoft Store, or download Git manually from https://git-scm.com/download/win. |

### Troubleshooting commands

Configure Git user name:
```bat
git config --global user.name "Your Name"
```

Configure Git email:
```bat
git config --global user.email "you@example.com"
```

Add Trinity to User PATH:
```bat
install.cmd -AddToPath
```

Run Trinity via Git Bash:
```bat
./trinity.sh status
```

Start dashboard on an alternate port:
```bat
trinity dashboard -Port 7788
```

Stop running dashboard:
```bat
trinity dashboard -Stop
```

Enable long paths in Git:
```bat
git config --global core.longpaths true
```

Disable Codex when operating without a paid plan:
```bat
set TRINITY_DISABLE=codex
```

## Update and uninstall

### Update

1. Download the latest `trinity-vX.Y.Z.zip` from https://github.com/Boss720/The-Holy-Trinity/releases.
2. Extract the archive over your existing Trinity directory.
3. In each project repository, run:
```bat
trinity init D:\path\to\your-project
```

Toolkit files are updated. Existing project rules and notes (`AGENTS.md`, `PLAN.md`, `HANDOFF.md`) are preserved.

### Uninstall

1. Remove Trinity from your User PATH:
```bat
install.cmd -RemoveFromPath
```

2. Delete the Trinity toolkit folder.

3. Optional: Remove Trinity files from project repositories (`scripts\`, `trinity.cmd`, `trinity.sh`, `.claude\agents\`, `.claude\skills\army\`).
