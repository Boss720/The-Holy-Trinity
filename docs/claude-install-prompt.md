# Automated Installation via Claude Code

This guide provides prompts to automate Trinity installation and updates using Claude Code.

## Fresh installation prompt

Copy and paste the text block below into a Claude Code session in any terminal.

```text
Install Trinity on this Windows machine by following these instructions:

1. Locate the latest release:
   Query https://api.github.com/repos/Boss720/The-Holy-Trinity/releases/latest.
   Extract the download URLs for trinity-v*.zip and trinity-v*.zip.sha256 from assets[].browser_download_url.

2. Download assets:
   Create a temporary directory under %TEMP% (for example, %TEMP%\trinity-install).
   Download both the zip file and the .sha256 file into that directory.

3. Verify checksum:
   Calculate the SHA-256 hash of the downloaded zip using certutil or PowerShell Get-FileHash.
   Compare the computed hash against the value in the .sha256 file.
   If the hashes do not match, stop immediately and report the mismatch.

4. Extract files:
   Extract the zip contents into %LOCALAPPDATA%\Programs\trinity.

5. Run installer:
   Display the command first, then run:
   install.cmd -InstallGit -AddToPath -Yes

6. Inspect doctor checks:
   Examine the doctor output. For each [FAIL] or [WARN] check, apply the recommended fix:
   - Ask the user before running any agent installation command (Claude Code, Codex, Antigravity).
   - Never run login commands (such as claude auth login, codex login, or interactive agy).
   - If authentication is required, instruct the user to run the login command themselves because it opens a browser.

7. Initialize project:
   Ask the user for the absolute path to their target git repository.
   Run trinity init <path> using the provided path.

8. Verify setup:
   Navigate to the target project directory.
   Run trinity doctor.
   Run trinity status.
   Report the final status with exact output evidence.

Operating rules:
- Show each command before running it.
- Run one command at a time.
- Do not request administrator elevation.
- Do not change execution policy globally.
- Do not edit files outside %LOCALAPPDATA%\Programs\trinity and the target project repository.
- Stop and report on any unexpected error with the exact error message.
```

## Update prompt

Copy and paste the text block below into Claude Code to update an existing Trinity installation to the latest release.

```text
Update the Trinity installation on this machine to the latest release:

1. Query https://api.github.com/repos/Boss720/The-Holy-Trinity/releases/latest for the latest release assets.
2. Download the latest trinity-v*.zip and trinity-v*.zip.sha256 into a temp folder.
3. Compute the SHA-256 hash of the zip file and verify it against the .sha256 file. Stop on mismatch.
4. Extract the zip contents over %LOCALAPPDATA%\Programs\trinity, replacing existing toolkit files.
5. Ask the user for the path to the project repository to update.
6. Run trinity init <path> to refresh toolkit scripts and subagents while preserving project documentation.
7. Change directory to the project repository and run trinity status.
8. Report the updated version and agent availability.

Operating rules:
- Show each command before running it.
- Run one command at a time.
- Do not edit files outside %LOCALAPPDATA%\Programs\trinity and the target project repository.
- Stop and report on any unexpected error with the exact error message.
```
