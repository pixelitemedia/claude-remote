# claude-remote

Remote sysadmin via Claude Code, run from a relay VPS.

A small DigitalOcean droplet runs Claude Code CLI with Remote Control enabled. The phone drives Claude on the relay; Claude SSHes from the relay into target servers (Rai/OpenClaw, etc.). Cloud sessions block outbound SSH — the relay exists to work around that.

```
Phone → Remote Control → Relay VPS (Claude Code) → SSH → Target servers
```

## Architecture

**Two kinds of Claude sessions on the relay:**

- **Root Claude** — manages the relay, provisions new projects, manages project session lifecycle. Stop when idle.
- **Project Claude** — runs as the `claude` user from `/home/claude/<project>/`. Each project has its own SSH key and a `config.json` listing hosts it may connect to. Always-on.

**Per-project layout:**

```
/home/claude/<project>/
├── key, key.pub           # ed25519, shared across hosts in this project
├── config.json            # name, aliases, hostname, user, default
├── CLAUDE.md              # project + target-server knowledge
└── .claude/skills/server-ssh/SKILL.md
```

## Repository layout

| Path | Purpose |
|---|---|
| [`CLAUDE.md`](CLAUDE.md) | Project-wide context for Claude Code |
| [`skills/server-sysadmin-bootstrap/`](skills/server-sysadmin-bootstrap/) | One-time relay VPS setup |
| [`skills/server-sysadmin-bootstrap/scripts/bootstrap.sh`](skills/server-sysadmin-bootstrap/scripts/bootstrap.sh) | Hardens the server and chains into other installs |
| [`skills/server-sysadmin-bootstrap/scripts/claude.sh`](skills/server-sysadmin-bootstrap/scripts/claude.sh) | Root + project tmux session launcher |
| [`skills/server-sysadmin/`](skills/server-sysadmin/) | Provisions per-target project workspaces |
| [`skills/server-sysadmin/references/project-CLAUDE.md.template`](skills/server-sysadmin/references/project-CLAUDE.md.template) | Stub copied into new projects |
| [`skills/server-ssh/`](skills/server-ssh/) | Operator skill — copied into each project workspace at provisioning time |
| [`skills/project-sessions/`](skills/project-sessions/) | Stateful session manager (start/stop/reconcile) |
| [`skills/project-sessions/scripts/claude-remote`](skills/project-sessions/scripts/claude-remote) | CLI: `list`, `status`, `start`, `stop`, `restart`, `rename`, `reconcile`, `install` |
| [`skills/project-sessions/commands/`](skills/project-sessions/commands/) | Slash commands (`/list-projects`, `/start-project`, …) |
| [`skills/project-sessions/references/cron.example`](skills/project-sessions/references/cron.example) | Reconcile cron snippet (+ optional Haiku check) |

## Skills

Three skills, used in order:

1. **`server-sysadmin-bootstrap`** — one-time per relay. Hardens the server, installs `claude.sh` and `claude-remote`, optionally adds the cron reconciler.
2. **`server-sysadmin`** — once per target server. Creates `/home/claude/<project>/` with its own keypair, `config.json`, and bundled `server-ssh` operator skill.
3. **`project-sessions`** — used continuously. Manages running project Claude sessions with persisted desired state.

## Getting started

On a fresh relay droplet, logged in as root:

**One-liner (recommended)** — run as root on a fresh droplet that already has your SSH key authorized:

```bash
curl -fsSL https://raw.githubusercontent.com/pixelitemedia/claude-remote/main/install.sh | bash
```

That clones the repo into `/root/claude-remote/`, installs the Claude Code CLI for root if missing, and runs the bootstrap unattended. Set `INTERACTIVE=1` to get the lockout-risk + cron prompts.

**Manual** — clone and drive Claude conversationally instead:

```bash
git clone https://github.com/pixelitemedia/claude-remote.git /root/claude-remote
cd /root/claude-remote
```

Then start Claude Code from `/root/claude-remote` and say **"set up sysadmin"**.

### What bootstrap does

1. Inspects `/root/.ssh/authorized_keys` — refuses to run unless a valid key is present.
2. Hardens the server: UFW (port 22 only), fail2ban, unattended-upgrades, key-only SSH, 1GB swap, `PermitRootLogin prohibit-password`.
3. Creates the `claude` user with passwordless sudo and mirrors root's `authorized_keys`.
4. Sets `allowBypassPermissions: true` for both root and the `claude` user (Remote Control sessions can't bypass prompts otherwise, which is unusable from a phone).
5. Installs Claude Code CLI per-user (`/root/.local/bin/claude` and `/home/claude/.local/bin/claude`).
6. Symlinks `claude.sh` and `claude-remote` into `/usr/local/bin/`.
7. Symlinks slash commands (`/list-projects`, `/start-project`, …) into `/root/.claude/commands/`.
8. Installs `/etc/logrotate.d/claude-remote` (weekly rotation, 4 weeks retained, compressed).
9. Offers to install cron entries (see [Cron](#cron) below).

Re-running is safe — every step is idempotent.

### 2. Provision a project (once per target server)

```
You: provision a new project called rai, host 1.2.3.4, user marcus
```

Claude will create `/home/claude/rai/` with its own ed25519 keypair, `config.json`, a stub `CLAUDE.md`, and a copy of the `server-ssh` operator skill. It will print the public key to paste into `/home/<user>/.ssh/authorized_keys` on the target server.

### 3. Start the project session

```
You: /start-project rai
```

Or equivalently `claude-remote start rai`. This:
- Marks `desired_state=running` in `/var/lib/claude-remote/state.json`
- Launches `claude --remote-control -n "<label>"` inside tmux — a fresh single-session Remote Control daemon
- The cron reconciler will **resume** it (preserving conversation history) if it ever crashes — see `claude-remote resume` / `/resume-project` to manually resume the latest prior session

### 4. Connect from your phone

Open Remote Control on the phone and pick the session. You're now driving the project Claude, which can SSH into the target server using its own per-project key.

## Day-to-day commands

### `claude.sh` — direct tmux launcher (root)

Installed at `/usr/local/bin/claude.sh` by bootstrap.

```bash
claude.sh                   # Root session (start or reattach)
claude.sh stop              # Stop root session
claude.sh status            # Root session status
claude.sh <project>         # Project session (start or reattach — delegates to claude-remote)
claude.sh <project> stop    # Stop project session
claude.sh <project> status  # Project session status
claude.sh list              # All sessions + available projects
```

Stop the root session when not actively managing the relay (`claude.sh stop`). Project sessions stay always-on.

### `claude-remote` — stateful session manager (root)

Installed at `/usr/local/bin/claude-remote` by bootstrap (via the `project-sessions` skill).

```bash
claude-remote list                       List all projects + desired vs actual state
claude-remote status [project]           Detailed status (falls back to list)
claude-remote sessions <project>         List prior Claude sessions for a project.
                                         Interactive: prompts to pick one and resumes
                                         it. Non-TTY: just prints the table.
claude-remote start <project>            Mark desired=running and start tmux (fresh session)
claude-remote resume <project> [sid]     Mark desired=running and resume a session. No
                                         sid → latest. With sid (full UUID or unique
                                         8-char prefix) → that specific one, stopping
                                         the current session first if one is running.
claude-remote stop <project>             Mark desired=stopped and kill tmux
claude-remote restart <project>          Stop then start (fresh)
claude-remote rename <project> <label>   Set the Remote Control session label in config.json
claude-remote reconcile                  For each desired=running project that's down,
                                         bring it back via resume (history preserved)
claude-remote install                    Re-install symlinks and slash commands (rarely needed)
claude-remote root <subcommand>          Manage the root (operator) session — see below
```

State at `/var/lib/claude-remote/state.json`, log at `/var/log/claude-remote.log`.

### Persistent root session (opt-in)

The root session (root Claude managing the relay itself) is normally transient — `claude.sh` to start/attach, `claude.sh stop` when idle. To make it persistent so the cron reconciler resumes it on crash:

```bash
claude-remote root start            # start fresh; mark desired=running
claude-remote root resume           # resume latest prior session; mark desired=running
claude-remote root resume <sid>     # resume a specific session
claude-remote root sessions         # interactive picker over prior sessions
claude-remote root stop             # mark desired=stopped (disenrolls from reconcile)
claude-remote root status           # current state (running, desired, label)
claude-remote root rename "<label>" # change the Remote Control label (default "🛠️ 🌐 🧠 - Sysadmin (root)")
```

Once `desired_state=running` is set, the reconciler treats root just like any other project: if the `claude-root` tmux session goes down, it gets resumed (history preserved) on the next cron tick. Stopping with `claude-remote root stop` disenrolls it — useful when you're done administering for the night and want the reconciler to leave it alone.

State for root lives under `state.json`'s top-level `root` object (separate from `projects`). The label, last-started/stopped/reconciled timestamps, and the desired state all live there.

### Picking a specific prior session

To switch the running project session to a specific prior conversation:

```bash
claude-remote sessions rai
# Sessions for rai (most recent first):
#
# #    ID         WHEN             MSGS   FIRST USER MESSAGE
# 1    a3f0c9d2   2026-05-11 14:30 42     check the openclaw service
# 2    7e1b8455   2026-05-10 09:15 17     restart the docker stack
# 3    ...
#
# Pick a session number to resume (Enter to cancel): 2
```

The picker stops the currently-running session (if any) and resumes the chosen one. The Remote Control label is preserved. You can also skip the picker:

```bash
claude-remote resume rai 7e1b8455     # 8-char prefix is enough if unique
claude-remote resume rai 7e1b8455-... # full UUID also accepted
```

From root Claude's REPL, the equivalent slash command is `/sessions <project>` — Claude shows the table and asks which to pick.

### Remote Control session labels

Each project session shows up in the phone's session picker with a custom label. The default is:

> **🛠️🌐 - `<ReferenceName>` Sysadmin**

So a project provisioned with reference name "Rai" appears as `🛠️🌐 - Rai Sysadmin`. The label is stored in the project's `config.json` under `session_label` and is passed to `claude --remote-control -n "<label>"` (or `claude -r <sid> --remote-control -n "<label>" ''` when resuming) when the tmux session is started.

To change the label later:

```bash
claude-remote rename rai "🚀 Rai Production"
claude-remote restart rai
```

### Slash commands (root Claude REPL)

Installed by bootstrap into `/root/.claude/commands/`:

| Command | Action |
|---|---|
| `/list-projects` | `claude-remote list` |
| `/project-status <name>` | `claude-remote status <name>` |
| `/sessions <name>` | `claude-remote sessions <name>` — list prior sessions and pick one to resume |
| `/start-project <name>` | `claude-remote start <name>` (fresh) |
| `/resume-project <name>` | `claude-remote resume <name>` (latest prior session) |
| `/stop-project <name>` | `claude-remote stop <name>` |
| `/reconcile-projects` | `claude-remote reconcile` |
| `/health` | `claude-remote health` — disk, sessions, alerts, cron status |

### Cron

Bootstrap offers to install three entries to root's crontab:

```
*/5 * * * * /usr/local/bin/claude-remote reconcile
17 */2 * * * /usr/local/bin/check-disk-alerts.sh 90
23 4 * * 0 /usr/local/bin/claude-update.sh
```

- **reconcile** (every 5 min) — restart any `desired=running` session that's down. Pure shell, no LLM cost.
- **check-disk-alerts.sh** (every 2 hours) — appends to `/root/.claude/system-alerts.md` if any non-tmpfs partition is ≥ 90% used. Root Claude reads that file at session start and surfaces today's entries (see `/root/CLAUDE.md`).
- **claude-update.sh** (weekly Sun 04:23 UTC) — re-runs the Claude Code installer for both root and the claude user, brings them to the latest version. **Skipped automatically if any tmux session is running** so we never yank a binary out from under a live phone connection.

Log rotation: `/var/log/claude-remote.log` and `/var/log/claude-update.log` are weekly-rotated (4 weeks retained, compressed) via `/etc/logrotate.d/claude-remote`.

See [`cron.example`](skills/project-sessions/references/cron.example) for an optional Haiku-driven hourly health check on top of these.

### Health check

```bash
claude-remote health   # or /health from root Claude
```

Reports: total disk usage of `~/.claude/projects/`, per-workspace session counts and size, current partition usage, today's system alerts, and whether all three cron entries are installed. Color-flags concerns advisory only (no auto-action) — yellow for ≥ 200 sessions or ≥ 1G in one workspace, ≥ 80% partition usage, or missing cron entries.

## Key gotchas

These cost time during the original build. Don't relearn them:

1. SSH commands need `-T -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10` or they hang in non-interactive sessions.
2. Workspace trust must be pre-set (`hasTrustDialogAccepted: true` in `~/.claude.json`) or Claude sits at the trust dialog. Bootstrap handles `/root`; provisioning handles each project workspace.
3. `--dangerously-skip-permissions` is blocked in Remote Control sessions by design. Use `allowBypassPermissions: true` in `~/.claude/settings.json` instead (root only).
4. `claude remote-control` is a **positional** subcommand, not `--remote-control`.
5. Use tmux, not screen.
6. User-level systemd services need `--user` on both `systemctl` and `journalctl`.

## VPS sizing

| Size | Notes |
|---|---|
| $4/mo | Works but tight |
| $6/mo (1GB) | Comfortable for one project |
| $12/mo (2GB) | Needed for multiple parallel project sessions |

## Status

Working but Remote Control drops connections occasionally — a known upstream issue. The Agent SDK was evaluated as an alternative; staying with the current approach for now.
