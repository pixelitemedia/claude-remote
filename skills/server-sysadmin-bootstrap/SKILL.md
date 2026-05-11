---
name: server-sysadmin-bootstrap
description: One-time installer for a fresh Claude Code relay VPS. Use this skill on the root Claude session of a newly-created droplet to harden the server, create the `claude` user, install the claude.sh tmux launcher, and chain into the project-sessions skill to set up the stateful session manager and slash commands. Triggers on phrases like "set up sysadmin", "run initial setup", "bootstrap this server", "harden this relay". Do NOT use for provisioning per-target project workspaces — that's the `server-sysadmin` skill. Do NOT use inside a project Claude session.
---

# server-sysadmin-bootstrap

You are root Claude on a brand-new relay VPS. This skill performs the **one-time** setup that turns a vanilla droplet into a relay that can host project Claude sessions.

It is separated from `server-sysadmin` (provisioning per-target workspaces) deliberately — bootstrap is a one-shot, provisioning runs many times.

## The flow

### Step 0 — verify SSH key access BEFORE doing anything

The bootstrap disables SSH password auth. If root has no working SSH key, the user gets locked out the moment sshd reloads. **You must verify keys before running the script.**

1. Inspect `/root/.ssh/authorized_keys`:
   ```bash
   ls -la /root/.ssh/
   ssh-keygen -l -f /root/.ssh/authorized_keys 2>/dev/null || echo "MISSING OR INVALID"
   ```
2. Report back to the user: how many keys, fingerprints, whether they parse as valid SSH public keys.
3. Ask the user to confirm: **"Can you SSH in as root using one of these keys right now? Test from a second terminal."** Wait for confirmation.
4. **If `authorized_keys` is missing, empty, or invalid, do NOT run bootstrap.** Offer to help set one up:
   ```bash
   mkdir -p /root/.ssh && chmod 700 /root/.ssh
   # User pastes their ssh-ed25519 / ssh-rsa public key:
   nano /root/.ssh/authorized_keys
   chmod 600 /root/.ssh/authorized_keys
   ```
   Then re-test from a second terminal before proceeding.

The script itself enforces this with a pre-flight check and refuses to run if `authorized_keys` is missing, empty, or unparseable. It also prompts interactively unless invoked with `-y`.

### Step 1 — run bootstrap

Once Step 0 is satisfied:

```bash
bash scripts/bootstrap.sh        # interactive — prompts to confirm lockout risk and cron install
bash scripts/bootstrap.sh -y     # non-interactive — assumes yes to everything, including cron
```

What it does:

- **Pre-flight**: re-checks `authorized_keys` (hard fail if invalid)
- Creates the `claude` user with passwordless sudo
- Mirrors root's `authorized_keys` to `/home/claude/.ssh/`
- Installs UFW (port 22 only), fail2ban, unattended-upgrades, tmux
- Creates a 1GB swap file if none exists
- Disables SSH password auth + sets `PermitRootLogin prohibit-password`
- Symlinks `scripts/claude.sh` → `/usr/local/bin/claude.sh` (so edits in the skill repo propagate)
- Pre-authorizes workspace trust in `/root/.claude.json` for `/root`
- Sets `allowBypassPermissions: true` in `/root/.claude/settings.json`
- Writes a starter `/root/CLAUDE.md`
- **Chains into project-sessions install** if that skill is present as a sibling — symlinks `claude-remote` and slash commands, creates `/var/lib/claude-remote/`
- **Offers to install the cron reconciler** (`*/5 * * * * /usr/local/bin/claude-remote reconcile`). With `-y` it's installed; without, it's prompted.

### Step 2 — hand off to `server-sysadmin`

After bootstrap finishes, tell the user:
- "Bootstrap complete. The relay is hardened and `claude-remote` is installed."
- "Next: provision a target server. Tell me a name, hostname, and user, and I'll set up its project workspace." (This invokes the `server-sysadmin` skill.)

If `claude.sh` or `claude-remote` are missing from PATH afterwards, fall back to symlinks (not copies — we want edits in the skill repo to propagate):

```bash
find / -name claude.sh -path '*/server-sysadmin-bootstrap/*' 2>/dev/null
find / -name claude-remote -path '*/project-sessions/*' 2>/dev/null
chmod +x <found_path>
ln -sfn <found_path> /usr/local/bin/<basename>
```

## What this skill ships

- `scripts/bootstrap.sh` — the idempotent installer
- `scripts/claude.sh` — tmux session launcher, installed at `/usr/local/bin/claude.sh`

`claude.sh` provides `claude.sh` (root session), `claude.sh stop`, `claude.sh status`, `claude.sh list`, and `claude.sh <project> [stop|status]`. For projects it delegates to `claude-remote` when installed, so desired-state stays coherent.

## Key gotchas

These are pre-baked into the script but worth knowing:

1. SSH commands need `-T -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10` or they hang. Not relevant to bootstrap itself (no outbound SSH), but the script writes scripts/configs that follow this.
2. Workspace trust must be pre-set (`hasTrustDialogAccepted: true` in `~/.claude.json`) or Claude sits at the trust dialog. Bootstrap does this for `/root`.
3. `--dangerously-skip-permissions` is blocked in Remote Control sessions by design. Bootstrap sets `allowBypassPermissions: true` in `/root/.claude/settings.json` instead.
4. `claude remote-control` is a **positional** subcommand, not `--remote-control`.
5. Use tmux, not screen.
6. User-level systemd services need `--user` on both `systemctl` and `journalctl` — not relevant here, but the bundled `server-ssh` skill knows this.

## Hard rules

- Never run `bootstrap.sh` on a server that already has production workloads without explicit user confirmation. It modifies SSH config and firewall rules.
- Never run bootstrap if you haven't verified Step 0. The script will refuse, but the user can confuse themselves with `-y` — always do Step 0 with them.
- Never install the cron reconciler on a relay that doesn't yet have any provisioned projects. It's harmless (no-op), but offer to defer until at least one project exists.
