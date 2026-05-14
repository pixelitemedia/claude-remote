# CLAUDE.md — claude.remote

Source for the **Remote Sysadmin via Claude Code Relay** project. The runtime lives on a small Linux VPS (the "relay"); this directory holds the skills, scripts, and notes that get deployed to it. User-facing documentation lives in [README.md](README.md) — don't duplicate it here.

## What you're working on

A relay VPS runs Claude Code with Remote Control. The phone drives Claude on the relay; Claude SSHes from the relay into target servers (cloud sessions block outbound SSH — the relay exists to work around that).

```
Phone → Remote Control → Relay VPS (Claude Code) → SSH → Target servers
```

## Architecture you should know

Two kinds of Claude sessions live on the relay:

- **Root Claude** — manages the relay, provisions projects, manages session lifecycle. Stopped when idle.
- **Project Claude** — runs as the `claude` user from `/home/claude/<project>/`. Each project owns its keypair and a `config.json` listing the hosts it may SSH into. Always-on.

Per-project layout on the relay:

```
/home/claude/<project>/
├── key, key.pub           # ed25519, shared across hosts in this project
├── config.json            # name, aliases, hostname, user, default
├── CLAUDE.md              # project + target-server knowledge
└── .claude/skills/server-ssh/SKILL.md
```

Persisted relay state (managed by `claude-remote`):

- `/var/lib/claude-remote/state.json` — desired state per project
- `/var/log/claude-remote.log` — reconcile + start/stop log

## Skills in this repo

- **`server-sysadmin-bootstrap`** — root Claude only. One-time per relay. Triggers: "set up sysadmin", "bootstrap this server". Hardens the VPS, creates the `claude` user, installs `claude.sh` and `claude-remote`, chains into `project-sessions install`, optionally adds the cron reconciler.
- **`server-sysadmin`** — root Claude only. Once per target server. Triggers: "provision a new project", "add a server". Creates `/home/claude/<project>/` with keypair, `config.json` (including the Remote Control `session_label`), project `CLAUDE.md`, and a copy of `server-ssh`.
- **`project-sessions`** — root Claude only. Used continuously. Ships `claude-remote` and slash commands (`/projects`, `/start-project`, `/stop-project`, `/reconcile-projects`, `/project-status`). State + reconciliation live here.
- **`server-ssh`** — top-level skill at `skills/server-ssh/`, copied by `server-sysadmin` into each provisioned project's `.claude/skills/server-ssh/`. **Only valid inside a project Claude session** — do not trigger from root Claude or from the repo top-level (no `config.json` there). Reads `config.json`, uses the project's local `key`, covers health checks / systemctl / journalctl / Docker / files / packages. Hard boundary: only SSHes to hosts in `config.json`.

## Behavioral constraints (gotchas)

These are baked into the scripts but matter when you write or modify them:

1. **SSH commands must use** `-T -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10` or they hang in non-interactive sessions.
2. **Workspace trust must be pre-set** (`hasTrustDialogAccepted: true` in `~/.claude.json`) or Claude sits at the trust dialog.
3. **`--dangerously-skip-permissions` is blocked in Remote Control sessions** by design. For root, use `allowBypassPermissions: true` in `/root/.claude/settings.json` instead.
4. **Remote Control: use the top-level `--remote-control` flag, not the `remote-control` subcommand.** Subcommand = multi-session daemon (capacity 32) with no `--continue`/`--resume` support — sessions disappear from the picker on every restart. Flag = single-session (capacity 1, fine for phone-driven use) and is the only form that combines with `-r`/`--continue` for real resume.
5. **Use tmux**, not screen.
6. **User-level systemd services** need `--user` on both `systemctl` and `journalctl`.
7. **Resuming a Remote Control session requires `-r <session-id>` and a trailing empty-string positional prompt arg**: `claude -r <sid> --remote-control -n "<label>" ''`. The trailing `''` satisfies the CLI's "prompt required when resuming under RC" check without pushing a new user message; without it the daemon waits for stdin and exits. `-c` (continue most recent) alone fails with "No conversation found to continue" under RC — you must look up the latest session ID. `claude-remote resume` and `reconcile` do the lookup from `~/.claude/projects/<encoded-workspace>/*.jsonl` (newest mtime wins).
8. **Each project session has a custom Remote Control label**: pass `-n "<label>"` to `claude --remote-control` (and to the resume invocation). The label lives in the project's `config.json` as `session_label`; default template is `🛠️ 🌐  [<project>]  Sysadmin`. Project Claude is expected to `/rename` to a topic-aware label (`🛠️ 🌐  [<project>]  <topic>`) after the first user message — see each project's `CLAUDE.md` for the instruction. `claude-remote rename <project> "<label>"` updates the persistent default in `config.json`.
9. **`sudo -u <user>` strips PATH**, so `~/.local/bin` (where the user-scoped `claude` lives) is not searched. When invoking `claude` for the relay's `claude` user via sudo/tmux, use the absolute path `/home/claude/.local/bin/claude` — `bash -lc` works too but quoting gets messy when labels contain spaces/emoji.

## Hard rules

- Never copy `claude.sh` or `claude-remote` into `/usr/local/bin/` — always symlink. Edits in the repo must propagate.
- Never run `bootstrap.sh` without verifying `/root/.ssh/authorized_keys` has working keys. The script enforces this, but the SKILL flow asks Claude to verify with the user first.
- Never overwrite an existing project's keypair without explicit confirmation.
- Never paste a project's private `key` anywhere. Only `key.pub` goes on target servers.
- Cron reconciler only auto-restarts projects with `desired_state=running`. It must never auto-stop anything.

## Preferences (inherited from parent CLAUDE.md)

- Concise and practical
- Prefer editing existing files
- No unnecessary comments / docstrings / boilerplate
- Ask before large or irreversible changes

## When in doubt

- **User-facing docs** (how to install, day-to-day commands, troubleshooting): put it in [README.md](README.md), not here.
- **Skill-specific behavior** (when to trigger, step-by-step flows): put it in the skill's `SKILL.md`, not here.
- **This file**: project-wide architecture, skill inventory, behavioral constraints, hard rules.
