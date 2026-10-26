---
name: trinity-dashboard
description: Open the Holy Trinity dashboard in the browser - the live local page showing Claude, Codex and Antigravity tasks, models, tokens and chats across every trinity repo, served by the Holy trinity checkout. Use when the user says "open the dashboard", "show the dashboard", "trinity dashboard", "start the dashboard", "dashboard status", "stop the dashboard", or wants to watch the agents or workers in the browser.
---

# Trinity dashboard

Opens the Holy Trinity dashboard: `scripts\dashboard.ps1` from the Holy trinity main checkout (`D:\AI\projects\Dev\Projects\Holy trinity`), on `http://localhost:7777/` or the next port. Spec: `docs/dashboard.md`.

The page lists every trinity repo in the registry, Holy trinity included. There is no URL filter for one repo.

The page must come from Holy Trinity's own server. Never open a server on the port that this checkout did not start.

Run every command from the Holy trinity main checkout.

## Open it

1. Start Holy Trinity's server on the default port, or reopen the one its pid file tracks:

```bash
./trinity.sh dashboard
```

   It starts the server hidden and detached, saves its pid and port to `%USERPROFILE%\.trinity\dashboard.pid`, opens the page, and prints `Dashboard: http://localhost:<port>/`. If the tracked server is already up, it only reopens the page.

2. If step 1 fails with `dashboard server exited (code 2); is port 7777 busy?`, another server holds 7777. Do not open it. Start Holy Trinity's own on the next port:

```bash
./trinity.sh dashboard -Port 7788
```

   The port is read on first start only. Later `trinity dashboard` calls reuse the saved port.

3. Confirm the server is Holy Trinity's. Use the port from step 1 or 2 in place of `<port>`:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:<port>/api/state
```

```bash
curl -s http://localhost:<port>/api/state | grep -o '"scriptHash[A-Za-z]*":"[^"]*"'
```

```bash
curl -s http://localhost:<port>/api/state | grep -o 'Holy trinity' | head -1
```

   Pass when all three hold:
   - HTTP `200`.
   - The two `scriptHash` values are equal. A mismatch means the running script is stale: `./trinity.sh dashboard -Stop`, then start again.
   - `Holy trinity` is printed, so the repo is listed.

   If any check fails, say so. Do not claim it opened Holy Trinity.

From cmd (the user's terminal), in the repo root:

```bat
trinity.cmd dashboard
```

## Check it is up

- HTTP `503`: first collection still running. Wait about 5 s and retry.
- HTTP `500`: collector error. Read `dashboard-errors.log` in `%USERPROFILE%\.trinity`.

## Text status, no browser

```bash
./trinity.sh dashboard -Json
```

Prints the state JSON once and exits. Does not start the server.

## Stop it

```bash
./trinity.sh dashboard -Stop
```

Stops the tracked server and removes the pid file. It does not close the browser tab.

If `-Stop` says `Dashboard is not running` but port 7777 still answers, that server was not started by this checkout. Do not stop it on your own: it may belong to another repo or worktree agent. Only when the user says so: list it, then stop that pid.

```powershell
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -like '*dashboard.ps1*' } | Select-Object ProcessId,CommandLine
```

```powershell
Stop-Process -Id <pid>
```

## In Claude's browser pane

Only if the user asks for the in-app browser instead of the default browser: after step 3 passes, open `http://localhost:<port>/` with `mcp__Claude_Browser__preview_start` (url `http://localhost:<port>/`).

## Rules

- Open only a server that passed step 3. Never open a server you did not start from this checkout.
- Start and stop through the `trinity` command. Do not start a second `dashboard.ps1` on a port that is already taken.
- Do not kill a process you did not start without the user's yes.
- Do not change the bind address or add a non-loopback prefix. The server is loopback only by design.
- The dashboard's Merge and Cancel buttons act on real tasks: press them only when the user asks.
