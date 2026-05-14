---
name: project-sessions
description: Manage relay project Claude sessions — list, start, stop, restart, and auto-reconcile tmux sessions for /home/claude/<project>/ workspaces. Tracks desired state (running/stopped) in /var/lib/claude-remote/state.json so a cron job can restart anything that crashed. Use this skill on the root Claude session of the relay when the user wants to bring a project up, take one down, check what's running, see drift between intended and actual state, or set up monitoring. Triggers on phrases like "start the X project", "what's running", "list projects", "stop X", "is everything up", "restart the relay sessions". Do NOT use this skill inside a project Claude session — that's server-ssh's job for managing target servers, not relay-side sessions.
---

# project-sessions

You manage Claude project sessions on the relay VPS. Each project is a tmux session running `claude --remote-control -n "<label>"` from `/home/claude/<project>/` as the `claude` user — single-session Remote Control mode. Start/stop is recorded in a state file so a cron reconciler can bring back anything that crashed. The reconciler **resumes** the prior session (not fresh-starts) so conversation history is preserved across crashes.

Important: this is the top-level `--remote-control` flag, **not** the `claude remote-control` subcommand. The subcommand is a multi-session daemon (capacity 32) but has no `--continue`/`--resume` support — sessions disappear from the picker on every restart. The flag form is single-session (capacity 1) but supports resume, which is what we want for phone-driven continuity.

## Tooling

Everything is built on one CLI: **`claude-remote`** (installed at `/usr/local/bin/claude-remote` after first run of `claude-remote install`).

```
claude-remote list                       List all projects + desired vs actual state
claude-remote status [project]           Detailed status (falls back to list)
claude-remote sessions <project>         List prior Claude sessions for a project.
                                         Interactive: prompts to pick one and
                                         resumes it (stop+swap if one is running).
                                         Non-TTY: just prints the list.
claude-remote start <project>            Mark desired=running, start tmux (fresh session)
claude-remote resume <project> [sid]     Mark desired=running, resume a session.
                                         No sid → latest. With sid (full UUID or
                                         unique 8-char prefix) → that specific one,
                                         stopping the current session first.
claude-remote stop <project>             Mark desired=stopped, kill tmux session
claude-remote restart <project>          Stop then start (fresh)
claude-remote reconcile                  For each desired=running project that's down,
                                         bring it back via resume (history preserved)
claude-remote install                    Symlink the CLI and slash commands; create state dir
claude-remote root <subcommand>          Manage the root (operator) session — opt-in
                                         persistence. Subcommands mirror the project ones:
                                         status, start, resume [sid], stop, restart,
                                         sessions, rename <label>.
```

### Root session (opt-in)

The root session — root Claude managing the relay itself — is **not tracked by default**. The classic flow is `claude.sh` → start/attach → `claude.sh stop` when idle. To make root persistent (auto-resume on crash):

```bash
claude-remote root start          # mark desired=running, start fresh
claude-remote root resume         # mark desired=running, resume latest prior session
claude-remote root sessions       # pick a specific prior session
claude-remote root stop           # mark desired=stopped, kill tmux (disenrolls from reconcile)
```

State for root lives under `state.json` → `root` (label, desired_state, last_started/stopped/reconciled). The reconciler treats `root.desired_state=running` exactly like a project: if the tmux session is down, resume via `claude -r <sid> --remote-control -n "<label>" ''`.

Default label is `🛠️ 🌐 🧠  [root]  Sysadmin`; root Claude is expected to `/rename` it to a topic-aware suffix on the first message (see `/root/CLAUDE.md`). Persistent override: `claude-remote root rename "<label>"`.

State lives at `/var/lib/claude-remote/state.json`. Log lives at `/var/log/claude-remote.log`.

## Slash commands

Once `claude-remote install` has run, these are available in root Claude:

| Command | Action |
|---|---|
| `/projects` | `claude-remote list` |
| `/project-status <name>` | `claude-remote status <name>` |
| `/sessions <name>` | `claude-remote sessions <name>` — list prior sessions, pick one to resume |
| `/start-project <name>` | `claude-remote start <name>` (fresh) |
| `/resume-project <name>` | `claude-remote resume <name>` (continue latest) |
| `/stop-project <name>` | `claude-remote stop <name>` |
| `/reconcile-projects` | `claude-remote reconcile` (resumes drifted projects) |

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

- **`start` launches a fresh single-session Remote Control daemon**. No prior history. Use this when you want a clean conversation.
- **`resume` launches the latest prior session under Remote Control** — `claude-remote` looks up the most-recently-modified `.jsonl` in `~/.claude/projects/<encoded-workspace>/` and invokes `claude -r <sid> --remote-control -n "<label>" ''`. The trailing empty-string positional satisfies the CLI's "prompt required when resuming under RC" check without pushing a new user message. If no prior session exists, falls back to fresh `start`.
- **Reconcile resumes**, not fresh-starts. This is the main user-visible benefit of single-session mode: a crashed/restarted daemon comes back with the prior conversation intact.
- **State drift is highlighted** in `list` output: red row = desired running but actually stopped (will be resumed by reconcile within ~5min); yellow row = desired stopped but actually running (user started it manually — leave alone unless asked).
- **Reconcile only acts on desired=running** projects. It never auto-stops a project the user started via `claude.sh` directly.
- **Stop sets desired=stopped**, so reconcile won't fight you. Use this when intentionally taking a project offline.
- **State file is the source of truth for intent**, not for actual state. Actual state is always queried live via `tmux has-session`.

## Optional: Claude-driven cron (advanced)

The deterministic `claude-remote reconcile` is what you want for monitoring. But if the user wants periodic LLM-assisted checks (read logs, summarize anomalies, decide whether to restart a flapping project), see [`references/cron.example`](references/cron.example) for a commented Haiku-based pattern. Don't enable this without explicit user buy-in — it costs money per run.

## Hard rules

- Never start a session for a project that doesn't exist on disk under `/home/claude/<project>/`. If the user asks for one that's missing, suggest provisioning it via `server-sysadmin`.
- Always confirm before `claude-remote stop` on a project the user didn't name explicitly. Stopping a session interrupts a live phone conversation if the user is currently connected.
- `claude-remote` must run as root — it uses `sudo -u claude tmux ...` to manage the claude user's sessions.
