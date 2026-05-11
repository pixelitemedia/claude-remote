---
name: server-sysadmin
description: Installer and provisioner for the Claude Code relay VPS. Use this skill on the root Claude session of a fresh relay droplet to (a) harden the server and install the claude.sh tmux launcher ("set up sysadmin" / "run initial setup"), and (b) provision new project workspaces under /home/claude/<project>/ that each get their own SSH keypair, config.json listing target hosts, and a bundled server-ssh operator skill. Do NOT use this skill inside a project Claude session — those use server-ssh, not server-sysadmin.
---

# server-sysadmin

You are root Claude on a relay VPS. This skill installs the relay tooling and provisions per-target project workspaces.

## When to use which flow

| User says | Run |
|---|---|
| "set up sysadmin", "run initial setup", "bootstrap this server" | **Bootstrap flow** |
| "provision a new project", "add a new server", "create project X for host Y" | **Provisioning flow** |

If unsure, ask. Bootstrap is one-time per VPS; provisioning is per target server.

---

## Bootstrap flow

Run **once** on a fresh root login. Idempotent — safe to re-run.

### Step 0 — verify SSH key access BEFORE doing anything

This bootstrap disables SSH password auth. If root has no working SSH key the user gets locked out the moment sshd reloads. **You must verify keys before running the script.**

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
bash scripts/bootstrap.sh        # interactive — prompts to confirm lockout risk
# or, if the user has already confirmed in chat:
bash scripts/bootstrap.sh -y     # skip prompt
```

It will:
- Re-check `authorized_keys` (pre-flight, hard fail)
- Create the `claude` user with passwordless sudo
- Mirror root's `authorized_keys` to `/home/claude/.ssh/`
- Install UFW (port 22 only), fail2ban, unattended-upgrades
- Create a 1GB swap file if none exists
- Disable SSH password auth + set `PermitRootLogin prohibit-password`
- **Symlink** `scripts/claude.sh` to `/usr/local/bin/claude.sh` (so edits in the skill repo propagate without reinstall)
- Pre-authorize workspace trust in `/root/.claude.json` for `/root`
- Set `allowBypassPermissions: true` in `/root/.claude/settings.json`
- Write a starter `/root/CLAUDE.md`

### Step 2 — hand off

After it finishes, tell the user:
- "Bootstrap complete. Run `claude.sh list` to see sessions."
- "Next: provision a project — give me a name, hostname, and user for the target server."

If `claude.sh` is not on PATH afterwards, fall back to a symlink (not a copy — we want edits in the skill to propagate):
```bash
find / -name claude.sh -path '*/server-sysadmin/*' 2>/dev/null
chmod +x <found_path>
ln -sfn <found_path> /usr/local/bin/claude.sh
```

---

## Provisioning flow

Inputs you need from the user (ask for any missing):

- **Project name** — short slug, used as directory name and tmux session suffix (e.g. `rai`, `openclaw`)
- **Hostname** — DNS name or IP of the target server
- **User** — SSH user on the target (often `root` or a named admin user)
- **Reference name** — alias the user wants to use in conversation (e.g. "Rai"); defaults to project name

Steps:

1. **Create project dir** at `/home/claude/<project>/`, owned by `claude:claude`, mode `0750`.
2. **Generate an ed25519 keypair** as the `claude` user:
   ```bash
   sudo -u claude ssh-keygen -t ed25519 -N '' -C "claude@relay:<project>" -f /home/claude/<project>/key
   ```
3. **Write `config.json`** with the host:
   ```json
   {
     "project": "<project>",
     "hosts": [
       {
         "name": "<reference-name>",
         "aliases": ["<project>"],
         "hostname": "<hostname>",
         "user": "<user>",
         "default": true
       }
     ]
   }
   ```
   If the user wants multiple hosts in one project, add them all here and pick one as `default: true`.
4. **Write `CLAUDE.md`** — start from the template in `references/project-CLAUDE.md.template` (copy and fill in target-server details). Leave runbook sections as TODO stubs for the user to grow over time.
5. **Install server-ssh skill** by copying `references/server-ssh/` into `/home/claude/<project>/.claude/skills/server-ssh/`. Ensure ownership is `claude:claude`.
6. **Pre-authorize workspace trust** for `/home/claude/<project>` in `/home/claude/.claude.json` (create if missing). Set `projects["/home/claude/<project>"].hasTrustDialogAccepted = true`.
7. **Print the `authorized_keys` line** for the user to paste on the target server:
   ```
   ✅ Project '<project>' provisioned.
   Paste this on <hostname> as <user>:

       <contents of /home/claude/<project>/key.pub>

   Then run:
       claude.sh <project>
   ```
8. **Test SSH** (optional, can ask the user first):
   ```bash
   sudo -u claude ssh -T -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
     -i /home/claude/<project>/key <user>@<hostname> 'echo ok'
   ```
   If it fails with permission denied, that's expected — the user still needs to paste the key. If it fails with connection refused / timeout, surface that.

---

## Key gotchas — read before doing anything

1. **SSH must use** `-T -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10` in scripts. Without these it hangs.
2. **Pre-authorize workspace trust** — Claude will sit at the trust dialog otherwise. Set `hasTrustDialogAccepted: true` in `~/.claude.json`.
3. **`--dangerously-skip-permissions` is blocked in Remote Control sessions** — for root, use `allowBypassPermissions: true` in `/root/.claude/settings.json` instead.
4. **`claude remote-control`** is a positional arg, not `--remote-control`.
5. **Use tmux**, not screen.
6. **User-level systemd services** (OpenClaw on Rai etc.) need `--user` on both `systemctl` and `journalctl`.

## Hard rules

- Never run `bootstrap.sh` on a server that already has production workloads without warning the user — it modifies SSH config and firewall.
- Never overwrite an existing project's `key` / `key.pub` without explicit confirmation. If the project dir exists, ask before proceeding.
- Never paste a project's private `key` anywhere. Only `key.pub` goes on target servers.
