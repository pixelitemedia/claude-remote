---
name: server-ssh
description: SSH operator for the project's target servers. Use this skill whenever the user asks to check status, view logs, restart services, inspect Docker containers, read or edit files, manage packages, or run any administrative command on a remote host owned by this project. Hosts are defined in ./config.json (relative to the project's CLAUDE.md) — only SSH to hosts listed there. Trigger on phrases like "check the server", "restart X on <host>", "pull logs from <host>", "what's running on <host>", or any operational question that requires shell access to a remote machine. Do NOT use for managing the relay VPS itself — that's the root Claude's job.
---

# server-ssh

You SSH into the project's target servers and run sysadmin commands on the user's behalf. Each project has:

- `./config.json` — hosts you may connect to
- `./key` / `./key.pub` — ed25519 keypair (use `./key` as `-i`; never share `./key`)
- `./CLAUDE.md` — project-specific runbooks, service names, log paths, gotchas

## Discover hosts before acting

On first use in a session, read `./config.json` to learn what hosts exist. Schema:

```json
{
  "project": "rai",
  "hosts": [
    { "name": "Rai", "aliases": ["rai", "openclaw"], "hostname": "1.2.3.4", "user": "marcus", "default": true }
  ]
}
```

If the user names a host by alias, look it up in `config.json`. If they don't name one, use `default: true`. If multiple hosts match, ask which one.

## SSH invocation — always use these flags

Without these flags, SSH hangs in non-interactive Claude sessions. **Memorize this template:**

```bash
ssh -T -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  -i ./key <user>@<hostname> '<command>'
```

- `-T` — no pseudo-tty
- `BatchMode=yes` — never prompt for password / passphrase
- `StrictHostKeyChecking=no` — accept unknown host keys (we trust by IP via config)
- `ConnectTimeout=10` — fail fast on unreachable hosts

For commands that need a real shell (heredocs, complex pipes), use a heredoc:

```bash
ssh -T -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
  -i ./key <user>@<hostname> 'bash -s' <<'REMOTE'
set -euo pipefail
# multi-line commands here
REMOTE
```

## Common operations

| Goal | Command pattern |
|---|---|
| Uptime / health | `uptime; free -h; df -h` |
| All services | `systemctl list-units --type=service --state=running` |
| Service status | `systemctl status <unit>` (add `--user` for user units) |
| Service logs | `journalctl -u <unit> -n 200 --no-pager` (add `--user`) |
| Restart service | `sudo systemctl restart <unit>` |
| Docker containers | `docker ps -a` |
| Docker logs | `docker logs --tail 200 <name>` |
| Container restart | `docker restart <name>` |
| Process tree | `ps auxf` |
| Listening ports | `ss -tlnp` |
| Disk by dir | `du -sh /path/*` |
| Package install | `sudo apt-get install -y <pkg>` |
| Read file | `cat <path>` |
| Edit file | use `sed -i` or write via heredoc + `tee` |

## User-level systemd (e.g. OpenClaw on Rai)

If a service runs as a user unit (not system), `systemctl` and `journalctl` both need `--user`:

```bash
systemctl --user status openclaw
journalctl --user -u openclaw -n 200 --no-pager
```

Run those as the owning user (no `sudo`).

## Hard boundaries

- **Only SSH to hosts in `config.json`.** If the user asks you to connect somewhere else, refuse and tell them to add it to `config.json` first (or run provisioning on the relay).
- **Never read or print `./key`** (the private key). `./key.pub` is fine.
- **Confirm before destructive actions** on target servers: `rm -rf`, dropping databases, force-pushing, mass-killing processes, reinstalling packages with config changes. Read-only investigation is always fine.
- **Don't run `--dangerously-skip-permissions`** — it's blocked in Remote Control sessions anyway. Just answer the permission prompts normally.

## Output discipline

Long command output (>50 lines) — summarize, don't dump. Quote the lines that matter. If the user wants the raw output, they'll ask.

For multi-step diagnostics, narrate briefly: "checking service status… looks healthy. Now tailing logs for errors."

## Before you act — check the project's CLAUDE.md

The project's `CLAUDE.md` (one directory up from this skill) holds target-specific knowledge: service names, log paths, known issues, runbooks. Read it once per session before running unfamiliar commands.
