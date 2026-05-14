# claude-remote

A relay-VPS setup that turns any cheap Linux box into a phone-driven sysadmin running Claude Code.

```
Phone → Remote Control → Relay VPS (Claude Code) → SSH → Target servers
```

## Why this exists

Mobile Claude Code is great for chat, planning, and reading code on the go — but the moment you want it to actually *do* something on a real server (SSH in, restart a service, tail logs, dig out an issue at 2am), you hit walls:

- **Cloud Claude sessions can't SSH out.** The sandbox blocks outbound TCP, so you can't reach your servers directly from a phone session.
- **On-server Claude is fragile.** If you put Claude on the box you're trying to debug, then when the box is sick (OOM, network flap, disk full) your AI debugger goes down with it. Exactly when you need it most.
- **You want one operator, not many.** Running Claude separately on every server means scattered context, scattered credentials, scattered habits.

This project solves all three:

- ✅ **Drive Claude from your phone.** A Claude Code session lives in a tmux window on a cheap relay VPS. You connect from the iOS app via Remote Control — pick a session, type, get answers.
- ✅ **Full sysadmin powers.** Claude on the relay isn't sandboxed. It can SSH, edit configs, restart systemd units, manage Docker containers, run package upgrades — whatever you'd do from a shell.
- ✅ **Diagnose servers from outside, not inside.** The relay is a separate, lightly-loaded box. When your real servers panic, the relay stays up and Claude can SSH in to investigate from a calm vantage point.
- ✅ **One operator, many targets.** Each "project" on the relay is a Claude session pre-configured with its own SSH key and a list of hosts it's allowed to reach. Switch between target servers like switching tabs.
- ✅ **Crash recovery built in.** A 5-minute cron job notices if any session died and resumes it with conversation history intact. Your phone re-attaches; the conversation picks up where it left off.

The relay itself is tiny — $2-4/month is enough for one or two project sessions, $6/month is comfortable, $12/month handles many parallel projects. Works on any cloud (DigitalOcean, Linode, Hetzner, Vultr, AWS Lightsail, OVH, …) or any bare-metal Linux box you already have.

## Architecture

Two kinds of Claude sessions live on the relay:

- **Root Claude** — manages the relay itself, provisions new projects, lifecycle of project sessions. Runs from `/root`. Stop when idle, or enroll for auto-resume on crash.
- **Project Claude** — runs as the `claude` user from `/home/claude/<project>/`. Each project owns its own ed25519 SSH key and a `config.json` listing the target hosts it's allowed to reach. Always-on, auto-resumes on crash.

Per-project layout on the relay:

```
/home/claude/<project>/
├── key, key.pub           # ed25519 — only authorized for hosts in config.json
├── config.json            # target hosts (name, hostname, user, …)
├── CLAUDE.md              # project + target-server notes
└── .claude/skills/server-ssh/SKILL.md
```

State + reconcile log:

- `/var/lib/claude-remote/state.json` — desired state per project
- `/var/log/claude-remote.log` — reconcile + start/stop events

## Getting started

You need:

- A fresh Linux VPS (Ubuntu/Debian) with root SSH access
- Your SSH public key already in `/root/.ssh/authorized_keys` (most cloud-image installs do this for you)

### Install (one command)

Run this as root on the relay:

```bash
curl -fsSL https://raw.githubusercontent.com/pixelitemedia/claude-remote/main/install.sh | bash
```

That:
1. Clones the repo into `/root/claude-remote/`
2. Installs the Claude Code CLI for root if it isn't already there
3. Runs the bootstrap unattended — hardens the box, creates the `claude` user, installs the session manager + slash commands + cron jobs + log rotation

When it finishes, you have:

- `/usr/local/bin/claude.sh` — tmux launcher (root session + project sessions)
- `/usr/local/bin/claude-remote` — stateful project session manager
- `/usr/local/bin/check-disk-alerts.sh` and `/usr/local/bin/claude-update.sh` — health helpers run from cron
- Cron entries for reconcile (every 5 min), disk monitoring (every 2 hours), weekly Claude Code self-update
- Skills symlinked into `/root/.claude/skills/` so root Claude (running from `/root`) sees them

Re-running is safe — every step is idempotent.

#### Want to see what bootstrap will do before it does it?

```bash
INTERACTIVE=1 curl -fsSL https://raw.githubusercontent.com/pixelitemedia/claude-remote/main/install.sh | bash
```

`INTERACTIVE=1` switches off the default `--yes` mode and makes the bootstrap pause to confirm:

- **Lockout-risk check** — before disabling SSH password auth and setting `PermitRootLogin prohibit-password`, the script confirms you can definitely SSH in with a key. If you skip the check and your key turns out not to work, you'd be locked out as soon as `sshd` reloads. The interactive prompt is your last chance to back out.
- **Cron entries** — the three cron jobs (reconcile, disk monitor, weekly self-update) are written to root's crontab. Interactive mode prompts before doing this.

For automated installs (the default `curl|bash`) we just assume yes — appropriate for the common case of installing onto a fresh VPS where the SSH-key check has already passed.

### Install via Claude (easiest path for first-timers)

Don't want to paste shell commands yourself? Have Claude do the install end-to-end. Open a **fresh Claude session** (Claude Code on your Mac, Claude Desktop with bash access, or any Claude that can SSH) and paste this prompt, filling in the placeholder for `<IP_OR_HOSTNAME>` and picking one auth mode:

```
I want to install claude-remote on a fresh VPS. Details below.

VPS IP/hostname: <IP_OR_HOSTNAME>

Auth mode (PICK ONE, delete the others):

  A. I have not created the VPS yet — please generate me a fresh
     ed25519 SSH key first, save the private key to
     ~/.ssh/claude-remote-relay, show me the public key, and pause
     until I confirm I've pasted it into my VPS provider's "Add SSH
     Key" panel and provisioned the droplet.

  B. My SSH key is already authorized for root@<IP> (the provider
     installed it for me from cloud-init / SSH key panel). Key file:
     ~/.ssh/<keyname>

  C. The VPS is up and all I have is a root password. Password:
     <PASSWORD> — please generate a fresh ed25519 key for me, save
     the private key to ~/.ssh/claude-remote-relay, use sshpass to
     log in with the password, deploy the public key into
     /root/.ssh/authorized_keys, and from there proceed with the
     install over key-based SSH.

Repo: https://github.com/pixelitemedia/claude-remote
Installer: https://raw.githubusercontent.com/pixelitemedia/claude-remote/main/install.sh

Please:
  1. If mode A: generate ~/.ssh/claude-remote-relay (ed25519, no
     passphrase, mode 600), show me the public key, and wait for me
     to confirm the droplet is up before continuing.
  2. If mode C: generate ~/.ssh/claude-remote-relay (same as A),
     install sshpass if it's missing locally (brew install hudochenkov/sshpass/sshpass
     on macOS, apt-get on Linux), use the password to push the public
     key into root's authorized_keys, then immediately stop using
     password auth — every subsequent connection uses the new key.
  3. Verify you can SSH in as root with the key (key-only, no
     password).
  4. Run the one-line installer (curl ... install.sh | bash).
  5. After it finishes, run `claude-remote health` over SSH and report
     the output verbatim.
  6. Surface anything that looks like a warning, missing piece, or
     manual follow-up I need to do.

Don't bootstrap projects or start sessions in this run — just the
install + health check.
```

> **Note:** The fresh Claude session needs Bash + SSH access. Claude Code on a Mac is the cleanest fit. Claude Desktop also works if your environment has those tools.

After the install completes, you can connect from your phone via Remote Control to drive the new relay. The root session will appear in your session picker as **🛠️ 🌐 🧠  [root]  Sysadmin**.

### Provision your first target server

Open Claude Code on the relay as root (`claude.sh` to start the root session, or `claude-remote root resume` to start with auto-restart enrolled). Then:

```
You: provision a new project called agent, host agent.example.com, user john
```

Claude will:
1. Create `/home/claude/agent/` with its own keypair, `config.json`, and a copy of the operator skill
2. Print a public key to paste into `john@agent.example.com:~/.ssh/authorized_keys`
3. Test the connection from the relay

### Start the project session

```
You: /start-project agent
```

Or directly: `claude-remote start agent`. The tmux session starts, Claude registers it with Remote Control, and within seconds you'll see **🛠️ 🌐  [agent]  Sysadmin** in the iOS app's session picker. Tap it. You're now driving a Claude session that has SSH access to `agent.example.com` and nothing else. As soon as you send the first message, Claude updates the label to reflect the topic (e.g. **🛠️ 🌐  [agent]  systemd diagnosis**).

## Day-to-day

### `claude.sh` — direct tmux launcher

```bash
claude.sh                   # Root session (start or reattach)
claude.sh stop              # Stop root session
claude.sh status            # Root session status
claude.sh <project>         # Project session (start or reattach — delegates to claude-remote)
claude.sh <project> stop    # Stop project session
claude.sh <project> status  # Project session status
claude.sh list              # All sessions + available projects
```

### `claude-remote` — stateful session manager

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
claude-remote delete <project> [flags]   Fully remove a project (session + dir + state
                                         + history + remote authorized_keys lines).
                                         Flags: --yes, --keep-history, --keep-remote-keys.
claude-remote rename <project> <label>   Set the Remote Control session label in config.json
claude-remote reconcile                  Resume any desired=running project that's down
                                         (history preserved)
claude-remote health                     Disk, sessions, alerts, cron status
claude-remote install                    Re-install symlinks (skills + commands)
claude-remote root <subcommand>          Manage the root (operator) session — see below
```

### Persistent root session

Root Claude is normally transient — `claude.sh` to attach, `claude.sh stop` when idle. To make it auto-resume on crash like project sessions:

```bash
claude-remote root start            # start fresh; mark desired=running
claude-remote root resume           # resume latest prior session; mark desired=running
claude-remote root resume <sid>     # resume a specific session
claude-remote root sessions         # interactive picker over prior sessions
claude-remote root stop             # mark desired=stopped (disenrolls from reconcile)
claude-remote root status           # current state (running, desired, label)
claude-remote root rename "<label>" # change the Remote Control label
                                    # (default: "🛠️ 🌐 🧠  [root]  Sysadmin")
```

State for root lives under `state.json`'s top-level `root` object (separate from `projects`).

### Picking a specific prior session

Each project's conversation history is preserved across crashes. To switch a running project to an earlier conversation:

```bash
claude-remote sessions agent
# Sessions for agent (most recent first):
#
# #    ID         WHEN             MSGS   FIRST USER MESSAGE
# 1    a3f0c9d2   2026-05-11 14:30 42     check the systemd units
# 2    7e1b8455   2026-05-10 09:15 17     restart the docker stack
#
# Pick a session number to resume (Enter to cancel): 2
```

The picker stops the current session and resumes the chosen one. The Remote Control label is preserved. To skip the picker:

```bash
claude-remote resume agent 7e1b8455     # 8-char prefix is enough if unique
```

### Slash commands (root Claude REPL)

| Command | Action |
|---|---|
| `/projects` | `claude-remote list` |
| `/project-status <name>` | `claude-remote status <name>` |
| `/sessions <name>` | `claude-remote sessions <name>` — list prior sessions and pick one to resume |
| `/start-project <name>` | `claude-remote start <name>` (fresh) |
| `/resume-project <name>` | `claude-remote resume <name>` (latest prior session) |
| `/stop-project <name>` | `claude-remote stop <name>` |
| `/reconcile-projects` | `claude-remote reconcile` |
| `/health` | `claude-remote health` |

### Remote Control session labels

Each project session shows up in the phone's session picker with a label like:

> **🛠️ 🌐  [agent]  Sysadmin**

That's the initial placeholder — the prefix `🛠️ 🌐  [<project>]  ` is set by `claude --remote-control -n <label>` at tmux launch (stored in `config.json` as `session_label` if you want to override the default).

The interesting part: each project's `CLAUDE.md` tells Claude to **`/rename`** after the first user message with a topic-specific suffix, so the label becomes something like:

> **🛠️ 🌐  [agent]  systemd diagnosis**

…and updates as the conversation pivots. Root sessions follow the same pattern with the prefix `🛠️ 🌐 🧠  [root]  `. To force a persistent override:

```bash
claude-remote rename agent "🚀  [agent]  prod-only mode"
claude-remote restart agent
```

### Cron jobs

Bootstrap installs three entries to root's crontab:

```
*/5 * * * *  /usr/local/bin/claude-remote reconcile
17 */2 * * * /usr/local/bin/check-disk-alerts.sh 90
23 4 * * 0   /usr/local/bin/claude-update.sh
```

- **reconcile** (every 5 min) — restart any `desired=running` session that's down. Pure shell, no LLM cost.
- **check-disk-alerts.sh** (every 2 hours) — appends to `/root/.claude/system-alerts.md` if any non-tmpfs partition is ≥ 90% used. Root Claude reads this at session start and surfaces today's entries to you.
- **claude-update.sh** (weekly Sun 04:23 UTC) — re-runs the Claude Code installer for both root and the claude user. **Skipped automatically if any tmux session is running** so a live phone connection never has its binary swapped out from under it.

Log rotation (`/etc/logrotate.d/claude-remote`) keeps weekly rotations of `claude-remote.log` and `claude-update.log` for 4 weeks, compressed.

### Health check

```bash
claude-remote health   # or /health from root Claude
```

Reports: total disk usage of `~/.claude/projects/`, per-workspace session counts + size + date range, current partition usage, today's system alerts, and whether all three cron entries are installed. Yellow flags ≥ 200 sessions or ≥ 1G in one workspace, ≥ 80% partition usage, or missing cron entries. Advisory only — never auto-deletes anything.

## Repository layout

| Path | Purpose |
|---|---|
| [`install.sh`](install.sh) | One-liner installer (curl \| bash entry point) |
| [`CLAUDE.md`](CLAUDE.md) | Project-wide context for Claude Code |
| [`skills/server-sysadmin-bootstrap/`](skills/server-sysadmin-bootstrap/) | One-time relay setup |
| [`skills/server-sysadmin-bootstrap/scripts/bootstrap.sh`](skills/server-sysadmin-bootstrap/scripts/bootstrap.sh) | Hardens the server and chains into project-sessions install |
| [`skills/server-sysadmin-bootstrap/scripts/claude.sh`](skills/server-sysadmin-bootstrap/scripts/claude.sh) | Root + project tmux launcher |
| [`skills/server-sysadmin-bootstrap/scripts/check-disk-alerts.sh`](skills/server-sysadmin-bootstrap/scripts/check-disk-alerts.sh) | Disk-usage monitor (cron) |
| [`skills/server-sysadmin-bootstrap/scripts/claude-update.sh`](skills/server-sysadmin-bootstrap/scripts/claude-update.sh) | Weekly CLI updater (cron) |
| [`skills/server-sysadmin/`](skills/server-sysadmin/) | Provisions per-target project workspaces |
| [`skills/server-ssh/`](skills/server-ssh/) | Operator skill — copied into each project workspace at provisioning time |
| [`skills/project-sessions/`](skills/project-sessions/) | Stateful session manager (start / stop / resume / reconcile) |
| [`skills/project-sessions/scripts/claude-remote`](skills/project-sessions/scripts/claude-remote) | The `claude-remote` CLI |
| [`skills/project-sessions/commands/`](skills/project-sessions/commands/) | Slash commands (`/projects`, `/start-project`, …) |
| [`skills/project-sessions/references/cron.example`](skills/project-sessions/references/cron.example) | Cron snippets + optional Haiku health-check pattern |

## Skills

Three skills installed for root Claude:

1. **`server-sysadmin-bootstrap`** — one-time per relay. Hardens the server, installs the CLI tools, installs cron jobs.
2. **`server-sysadmin`** — once per target server. Creates a project workspace under `/home/claude/<project>/` with its own keypair, `config.json`, and bundled operator skill.
3. **`project-sessions`** — used continuously. Manages running project sessions with persisted desired state and automatic crash recovery.

A fourth skill, **`server-ssh`**, is bundled into each provisioned project (not installed globally). It's what each project Claude uses to SSH into its target hosts.

## Key gotchas

These cost time during the original build. Worth knowing if you're modifying the scripts:

1. SSH commands in scripts need `-T -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10` or they hang in non-interactive sessions.
2. Claude Code workspace trust must be pre-set (`hasTrustDialogAccepted: true` in `~/.claude.json`) or Claude sits at the trust dialog. Bootstrap handles `/root`; provisioning handles each project workspace.
3. `--dangerously-skip-permissions` is blocked in Remote Control sessions by design. We set `allowBypassPermissions: true` in `~/.claude/settings.json` instead — for both root and the claude user. Without this, every Bash/Edit prompts via the phone, which is unworkable.
4. `claude --remote-control` is the single-session flag form; `claude remote-control` is a *positional subcommand* that's a different (multi-session) mode without resume support. Use the flag.
5. Use `tmux`, not `screen`.
6. User-level systemd services need `--user` on both `systemctl` and `journalctl`.

## VPS sizing

| Size | Notes |
|---|---|
| **$2-4/mo** (512MB-1GB) | Works for one or two projects. Low-RAM caveat: the Claude installer can OOM during extraction on very tight boxes — bootstrap handles this by copying root's binary to the claude user instead of re-downloading. |
| **$6/mo** (1GB) | Comfortable for a few projects |
| **$12/mo** (2GB) | Several parallel project sessions, plus the root session running persistently |

Works on any cloud or bare-metal Linux: DigitalOcean, Linode, Hetzner, Vultr, AWS Lightsail, OVH, IONOS, your own homelab.

## Status

Production-ready as a personal-use tool. Remote Control occasionally drops connections (a known upstream behavior in Claude Code) — the reconcile cron compensates by resuming any session that disconnects. Conversation history is preserved across the reconnect.
