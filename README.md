# claude-remote

Remote sysadmin via Claude Code, run from a relay VPS.

A small DigitalOcean droplet runs Claude Code CLI with Remote Control enabled. The phone drives Claude on the relay; Claude SSHes from the relay into target servers (Rai/OpenClaw, etc.). Cloud sessions block outbound SSH — the relay exists to work around that.

```
Phone → Remote Control → Relay VPS (Claude Code) → SSH → Target servers
```

## What's in here

| Path | Purpose |
|---|---|
| [`CLAUDE.md`](CLAUDE.md) | Project-wide context for Claude Code |
| [`skills/`](skills/) | Skills used by the relay |
| [`skills/server-sysadmin/`](skills/server-sysadmin/) | Installer/provisioner skill, run by root Claude on the relay |
| [`skills/server-sysadmin/scripts/bootstrap.sh`](skills/server-sysadmin/scripts/bootstrap.sh) | One-time relay VPS hardening + install |
| [`skills/server-sysadmin/scripts/claude.sh`](skills/server-sysadmin/scripts/claude.sh) | tmux session launcher (`claude.sh [project] [stop\|status]`) |
| [`skills/server-sysadmin/references/server-ssh/`](skills/server-sysadmin/references/server-ssh/) | Operator skill bundled into each project workspace |
| [`skills/server-sysadmin/references/project-CLAUDE.md.template`](skills/server-sysadmin/references/project-CLAUDE.md.template) | Stub copied into new projects |
| [`skills/project-sessions/`](skills/project-sessions/) | Stateful session manager for relay projects (start/stop/reconcile) |
| [`skills/project-sessions/scripts/claude-relay`](skills/project-sessions/scripts/claude-relay) | CLI: `list`, `status`, `start`, `stop`, `restart`, `reconcile`, `install` |
| [`skills/project-sessions/commands/`](skills/project-sessions/commands/) | Slash commands installed for root Claude (`/list-projects`, `/start-project`, …) |
| [`skills/project-sessions/references/cron.example`](skills/project-sessions/references/cron.example) | Cron snippet for the 5-min reconcile loop (+ optional Haiku check) |

## Getting started

On a fresh relay droplet:

1. Get the `server-sysadmin` skill onto root Claude (clone this repo or upload as a skill bundle).
2. Tell Claude **"set up sysadmin"** → runs `bootstrap.sh`: hardens the server (UFW, fail2ban, unattended-upgrades, key-only SSH, 1GB swap), creates the `claude` user, installs `claude.sh`, pre-authorizes workspace trust.
3. Tell Claude **"provision a new project called `<name>`, host `<hostname>`, user `<user>`"** → creates `/home/claude/<name>/` with its own keypair, `config.json`, `CLAUDE.md`, and a copy of `server-ssh`.
4. Paste the printed `authorized_keys` line on the target server.
5. Install the session manager: `bash skills/project-sessions/scripts/claude-relay install` (one-time per relay; sets up `/usr/local/bin/claude-relay`, slash commands, state dir).
6. `claude-relay start <project>` → starts the tmux session and records desired-state. Add a cron entry from [`cron.example`](skills/project-sessions/references/cron.example) for auto-restart on crash.
7. Connect from phone via Remote Control.

## Architecture

**Two kinds of Claude sessions on the relay:**

- **Root Claude** — manages the relay, provisions projects. Stop when idle.
- **Project Claude** — runs as `claude` user from `/home/claude/<project>/`. Each project has its own SSH key and a `config.json` listing hosts it may connect to. Always-on.

**Per-project layout:**

```
/home/claude/<project>/
├── key, key.pub           # ed25519, shared across hosts in this project
├── config.json            # name, aliases, hostname, user, default
├── CLAUDE.md              # project + target-server knowledge
└── .claude/skills/server-ssh/SKILL.md
```

## Key gotchas

These cost us time during the original build. Don't relearn them:

1. SSH commands need `-T -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10` or they hang.
2. Workspace trust must be pre-set (`hasTrustDialogAccepted: true` in `~/.claude.json`) or Claude sits at the trust dialog.
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
