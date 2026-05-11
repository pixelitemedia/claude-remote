# CLAUDE.md — claude.remote

Local working directory for the **Remote Sysadmin via Claude Code Relay** project. The actual runtime lives on a DigitalOcean droplet (the "relay VPS"); this directory holds the source for skills, scripts, and notes that get deployed there.

## Purpose

A relay VPS that runs Claude Code CLI with Remote Control enabled, so the phone can drive Claude, and Claude SSHes from the relay into target servers (Rai/OpenClaw and others). Cloud sessions block outbound SSH — the relay exists to work around that.

```
Phone → Remote Control → Relay VPS (Claude Code) → SSH → Target servers
```

## Architecture

**Relay VPS** runs two kinds of Claude sessions:

- **Root Claude** — manages the relay itself, provisions new project workspaces. Stop when idle.
- **Project Claude** — runs as `claude` user from `/home/claude/<project>/`. Each project owns a keypair and a `config.json` listing the hosts it may SSH into. Always-on.

**Per-project layout** (`/home/claude/<project>/`):

| File | Purpose |
|---|---|
| `key` / `key.pub` | ed25519 SSH keypair, shared across all hosts in the project |
| `config.json` | Hosts: name, aliases, hostname, user, default |
| `CLAUDE.md` | Project guidelines + target-server knowledge |
| `.claude/skills/server-ssh/SKILL.md` | Operator skill |

## Skills

- **`server-sysadmin`** — installer/provisioner. Root Claude only. Trigger: "set up sysadmin" or "run initial setup". Contains `scripts/bootstrap.sh`, `scripts/claude.sh`, and a bundled copy of `server-ssh` to install into each project.
- **`server-ssh`** — operator skill installed into every project. Reads `config.json`, builds SSH commands using the local `key`, covers health checks / systemctl / journalctl / Docker / files / packages / processes. Hard boundary: only SSHes to hosts in `config.json`.
- **`project-sessions`** — root Claude only. Stateful session manager. Ships `claude-relay` (CLI) and slash commands (`/list-projects`, `/start-project`, `/stop-project`, `/reconcile-projects`, `/project-status`). Records desired state in `/var/lib/claude-relay/state.json`; a cron reconciler brings back anything that crashed. Starting a project resumes its latest Claude session via `claude --continue remote-control`. Install with `bash skills/project-sessions/scripts/claude-relay install`.

## claude.sh — session launcher

Installed at `/usr/local/bin/claude.sh` on the relay. Run as root.

```bash
claude.sh                   # Root session (start or reattach)
claude.sh stop              # Stop root session
claude.sh status            # Check root session
claude.sh <project>         # Project session (start or reattach)
claude.sh <project> stop    # Stop project session
claude.sh <project> status  # Project session status
claude.sh list              # All sessions + available projects
```

## Key gotchas (do not relearn these)

1. **SSH must use** `-T -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10` — otherwise hangs in non-interactive sessions.
2. **Workspace trust must be pre-authorized** — set `hasTrustDialogAccepted: true` in `~/.claude.json` under `projects.<path>` so Claude doesn't sit at the trust dialog.
3. **`--dangerously-skip-permissions` is blocked in Remote Control sessions by design** — only works in direct sessions. For root, set `allowBypassPermissions: true` in `/root/.claude/settings.json` instead.
4. **Cloud sessions block outbound SSH/TCP** — the entire reason the relay exists.
5. **Use tmux, not screen** — better reattach.
6. **`claude remote-control`** is a positional arg, not `--remote-control`.
7. **User-level systemd services** (e.g. OpenClaw on Rai) need `--user` on both `systemctl` and `journalctl`.

## Provisioning a new project

1. Upload `server-sysadmin.skill` to root Claude on the relay.
2. "Set up sysadmin" → runs bootstrap: creates `claude` user with passwordless sudo, hardens (UFW port 22 only, fail2ban, auto-updates, 1GB swap, key-only SSH), installs `claude.sh`, pre-authorizes workspace trust, copies root's `authorized_keys` to the `claude` user, writes `/root/CLAUDE.md`.
3. "Provision a new project called `<name>`, host `<hostname>`, user `<user>`, reference name `<name>`" → creates the project dir, keypair, `config.json`, `CLAUDE.md`, installs `server-ssh`, pre-trusts the workspace, prints an `authorized_keys` line, tests the connection, starts tmux.
4. Paste the `authorized_keys` line on the target server.
5. `claude.sh <project>` → connect from phone via Remote Control.

## Per-project CLAUDE.md should include

Each project's `CLAUDE.md` (on the relay) gets target-specific knowledge:

- CLI commands and common operations
- Service names (systemd units, Docker containers)
- Config + log file locations
- Runbooks and known issues

For **OpenClaw / Rai**: see `github.com/pixelitemedia/openclaw-docs-skill` — and use the user's global `openclaw-docs` skill (grep `~/.claude/skills/openclaw-docs/versions/openclaw-docs.latest.md`) before answering factual OpenClaw questions.

## Open issues

| Issue | Status |
|---|---|
| Remote Control drops connections | Known. Looked at Agent SDK as alternative; staying on current approach. |
| `claude.sh` sometimes missing after bootstrap | Locate manually: `find / -name claude.sh -path '*/server-sysadmin/*' 2>/dev/null` then `cp` into `/usr/local/bin/` and `chmod +x`. |
| VPS sizing | $4 droplet tight, $6/mo (1GB) comfortable, $12/mo (2GB) for parallel projects. |

## Preferences (inherited from parent CLAUDE.md)

- Concise and practical
- Prefer editing existing files
- No unnecessary comments/docstrings/boilerplate
- Ask before large or irreversible changes
