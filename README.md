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

```bash
git clone https://github.com/pixelitemedia/claude-remote.git ~/claude-remote
cd ~/claude-remote
```

Then start Claude Code from `~/claude-remote` (so the three skills under `skills/` are picked up — symlink them into `/root/.claude/skills/` if needed) and follow the conversational flow below.

### 1. Bootstrap the relay (once)

```
You: set up sysadmin
```

Claude will:
1. Inspect `/root/.ssh/authorized_keys`, report fingerprints, and ask you to confirm you can SSH in with one of them from a second terminal.
2. Run `bash skills/server-sysadmin-bootstrap/scripts/bootstrap.sh` after you confirm.
3. The script hardens the server (UFW, fail2ban, unattended-upgrades, key-only SSH, 1GB swap), creates the `claude` user, installs `claude.sh` and `claude-remote`, and prompts to install the 5-minute reconcile cron.

Re-running is safe — the script is idempotent.

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
- Launches `claude --continue remote-control` inside tmux, resuming the latest session (not starting fresh)
- The cron reconciler will bring it back if it ever crashes

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
claude-remote start <project>            Mark desired=running and start tmux (resumes latest)
claude-remote stop <project>             Mark desired=stopped and kill tmux
claude-remote restart <project>          Stop then start
claude-remote rename <project> <label>   Set the Remote Control session label in config.json
claude-remote reconcile                  Restart any desired=running project that's down
claude-remote install                    Re-install symlinks and slash commands (rarely needed)
```

State at `/var/lib/claude-remote/state.json`, log at `/var/log/claude-remote.log`.

### Remote Control session labels

Each project session shows up in the phone's session picker with a custom label. The default is:

> **🛠️🌐 - `<ReferenceName>` Sysadmin**

So a project provisioned with reference name "Rai" appears as `🛠️🌐 - Rai Sysadmin`. The label is stored in the project's `config.json` under `session_label` and is passed to `claude remote-control --name "<label>"` when the tmux session is started.

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
| `/start-project <name>` | `claude-remote start <name>` |
| `/stop-project <name>` | `claude-remote stop <name>` |
| `/reconcile-projects` | `claude-remote reconcile` |

### Cron

Bootstrap offers to install:

```
*/5 * * * * /usr/local/bin/claude-remote reconcile
```

Pure shell, no LLM cost. See [`cron.example`](skills/project-sessions/references/cron.example) for an optional Haiku-driven hourly health check.

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
