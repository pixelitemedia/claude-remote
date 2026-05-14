---
name: server-sysadmin
description: Provisions a new project workspace on the relay VPS for an additional target server. Use this skill on the root Claude session when the user wants to "provision a new project", "add a server", "set up <name> as a target", or otherwise extend the relay to manage one more remote host. Creates /home/claude/<project>/ with its own ed25519 keypair, a config.json listing target hosts, a project-specific CLAUDE.md, and a bundled copy of the server-ssh operator skill. Do NOT use for the one-time relay bootstrap — that's server-sysadmin-bootstrap. Do NOT use inside a project Claude session — those use server-ssh, not server-sysadmin.
---

# server-sysadmin

You are root Claude on a relay VPS. This skill provisions per-target project workspaces. The relay itself must already be bootstrapped via `server-sysadmin-bootstrap` before you run this — verify by checking that `/usr/local/bin/claude.sh` exists and the `claude` user is present.

## Provisioning flow

Inputs you need from the user (ask for any missing):

- **Project name** — short slug, used as directory name and tmux session suffix (e.g. `agent`, `web1`)
- **Hostname** — DNS name or IP of the target server
- **User** — SSH user on the target (often `root` or a named admin user)
- **Reference name** — alias the user wants to use in conversation (e.g. "Agent"); defaults to project name

Steps:

1. **Create project dir** at `/home/claude/<project>/`, owned by `claude:claude`, mode `0750`. If the directory already exists, stop and ask the user whether to reuse or pick a different name — never overwrite an existing keypair.
2. **Generate an ed25519 keypair** as the `claude` user:
   ```bash
   sudo -u claude ssh-keygen -t ed25519 -N '' -C "claude@relay:<project>" -f /home/claude/<project>/key
   ```
3. **Write `config.json`** with the host and session label:
   ```json
   {
     "project": "<project>",
     "session_label": "🛠️ 🌐  [<project>]  Sysadmin",
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
   - `session_label` is the **initial** title shown in Remote Control's session picker. Convention: `🛠️ 🌐  [<project>]  Sysadmin` (two-space padding around the brackets, no inner spaces). Project Claude will `/rename` to a topic-aware suffix on the first user message per its CLAUDE.md.
   - If the user wants multiple hosts in one project, add them all to `hosts` and pick one as `default: true`.
4. **Write `CLAUDE.md`** — start from the template in `references/project-CLAUDE.md.template` (copy and fill in target-server details). Leave runbook sections as TODO stubs for the user to grow over time.
5. **Install server-ssh skill** by copying the sibling skill at `../server-ssh/` (i.e. `skills/server-ssh/` in the repo) into `/home/claude/<project>/.claude/skills/server-ssh/`. Ensure ownership is `claude:claude`.
6. **Pre-authorize workspace trust** for `/home/claude/<project>` in `/home/claude/.claude.json` (create if missing). Set `projects["/home/claude/<project>"].hasTrustDialogAccepted = true`.
7. **Print the `authorized_keys` line** for the user to paste on the target server:
   ```
   ✅ Project '<project>' provisioned.
   Session label: 🛠️ 🌐  [<project>]  Sysadmin
   Paste this on <hostname> as <user>:

       <contents of /home/claude/<project>/key.pub>

   Then start the session:
       claude-remote start <project>

   (To change the label later: claude-remote rename <project> "<new label>")
   ```
8. **Test SSH** (optional, ask the user first):
   ```bash
   sudo -u claude ssh -T -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
     -i /home/claude/<project>/key <user>@<hostname> 'echo ok'
   ```
   If it fails with permission denied, that is expected — the user still needs to paste the key. If it fails with connection refused / timeout, surface that.

## Key gotchas

1. **SSH must use** `-T -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10` in scripts. Without these it hangs.
2. **Pre-authorize workspace trust** — Claude sits at the trust dialog otherwise. Set `hasTrustDialogAccepted: true` in `~/.claude.json`.
3. **`claude remote-control`** is a positional subcommand, not a `--remote-control` flag.
4. **User-level systemd services** need `--user` on both `systemctl` and `journalctl`. The bundled `server-ssh` skill knows this — pass it along in the project's `CLAUDE.md` if relevant.

## Hard rules

- Never overwrite an existing project's `key` / `key.pub` without explicit confirmation. If the project dir exists, ask before proceeding.
- Never paste a project's private `key` anywhere. Only `key.pub` goes on target servers.
- Never SSH into the target server from this skill — that is the project Claude's job once it's running. Step 8 is a one-shot connectivity test, nothing more.
