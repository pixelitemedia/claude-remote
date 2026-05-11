---
name: project-sessions
description: Manage relay project Claude sessions — list, start, stop, restart, and auto-reconcile tmux sessions for /home/claude/<project>/ workspaces. Tracks desired state (running/stopped) in /var/lib/claude-remote/state.json so a cron job can restart anything that crashed. Use this skill on the root Claude session of the relay when the user wants to bring a project up, take one down, check what's running, see drift between intended and actual state, or set up monitoring. Triggers on phrases like "start the rai project", "what's running", "list projects", "stop openclaw", "is everything up", "restart the relay sessions". Do NOT use this skill inside a project Claude session — that's server-ssh's job for managing target servers, not relay-side sessions.
---

# project-sessions

You manage Claude project sessions on the relay VPS. Each project is a tmux session running `claude --continue remote-control` from `/home/claude/<project>/` as the `claude` user. Start/stop is recorded in a state file so a cron reconciler can bring back anything that crashed.

## Tooling

Everything is built on one CLI: **`claude-remote`** (installed at `/usr/local/bin/claude-remote` after first run of `claude-remote install`).

```
claude-remote list                List all projects + desired vs actual state
claude-remote status [project]    Detailed status (falls back to list)
claude-remote start <project>     Mark desired=running, start tmux session (resumes latest Claude session)
claude-remote stop <project>      Mark desired=stopped, kill tmux session
claude-remote restart <project>   Stop then start
claude-remote reconcile           For each desired=running project, restart if its session is down
claude-remote install             Symlink the CLI and slash commands; create state dir
```

State lives at `/var/lib/claude-remote/state.json`. Log lives at `/var/log/claude-remote.log`.

## Slash commands

Once `claude-remote install` has run, these are available in root Claude:

| Command | Action |
|---|---|
| `/list-projects` | `claude-remote list` |
| `/project-status <name>` | `claude-remote status <name>` |
| `/start-project <name>` | `claude-remote start <name>` |
| `/stop-project <name>` | `claude-remote stop <name>` |
| `/reconcile-projects` | `claude-remote reconcile` |

If a slash command is missing the argument, ask the user — but show them `claude-remote list` first so they can pick from existing projects.

## First-time setup (per relay)

Run once as root, after server-sysadmin bootstrap and at least one provisioned project:

```bash
bash skills/project-sessions/scripts/claude-remote install
```

That:
- Symlinks `claude-remote` to `/usr/local/bin/`
- Symlinks each slash command from `commands/` to `/root/.claude/commands/`
- Creates `/var/lib/claude-remote/` and an empty `state.json`
- Prints a suggested cron line — does **not** install cron automatically (ask the user first)

To enable monitoring (after confirming with the user):
```bash
(crontab -l 2>/dev/null | grep -v '/claude-remote reconcile'; \
 echo '*/5 * * * * /usr/local/bin/claude-remote reconcile') | crontab -
```

## Key behaviors

- **Start resumes**, doesn't reset. `claude-remote start <project>` invokes `claude --continue remote-control` so the latest Claude session in that workspace reattaches with its history intact. If no prior session exists, Claude Code falls back to a fresh one.
- **State drift is highlighted** in `list` output: red row = desired running but actually stopped (will be restarted by reconcile); yellow row = desired stopped but actually running (user started it manually — leave alone unless asked).
- **Reconcile only acts on desired=running** projects. It never auto-stops a project the user started via `claude.sh` directly.
- **Stop sets desired=stopped**, so reconcile won't fight you. Use this when intentionally taking a project offline.
- **State file is the source of truth for intent**, not for actual state. Actual state is always queried live via `tmux has-session`.

## Optional: Claude-driven cron (advanced)

The deterministic `claude-remote reconcile` is what you want for monitoring. But if the user wants periodic LLM-assisted checks (read logs, summarize anomalies, decide whether to restart a flapping project), see [`references/cron.example`](references/cron.example) for a commented Haiku-based pattern. Don't enable this without explicit user buy-in — it costs money per run.

## Hard rules

- Never start a session for a project that doesn't exist on disk under `/home/claude/<project>/`. If the user asks for one that's missing, suggest provisioning it via `server-sysadmin`.
- Always confirm before `claude-remote stop` on a project the user didn't name explicitly. Stopping a session interrupts a live phone conversation if the user is currently connected.
- `claude-remote` must run as root — it uses `sudo -u claude tmux ...` to manage the claude user's sessions.
