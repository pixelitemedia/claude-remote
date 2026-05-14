---
name: server-sysadmin
description: Provisions a new project workspace on the relay VPS for an additional target server. Use this skill on the root Claude session when the user wants to "provision a new project", "add a server", "set up <name> as a target", or otherwise extend the relay to manage one more remote host. Creates /home/claude/<project>/ with its own ed25519 keypair, a config.json listing target hosts, a project-specific CLAUDE.md, and a bundled copy of the server-ssh operator skill. Do NOT use for the one-time relay bootstrap — that's server-sysadmin-bootstrap. Do NOT use inside a project Claude session — those use server-ssh, not server-sysadmin.
---

# server-sysadmin

You are root Claude on a relay VPS. This skill provisions per-target project workspaces. The relay itself must already be bootstrapped via `server-sysadmin-bootstrap` before you run this — verify by checking that `/usr/local/bin/claude.sh` exists and the `claude` user is present.

## Provisioning flow

Before you do anything, gather what you need from the user — **ask for any missing**. Don't assume; don't pre-fill. Walk them through it conversationally.

### Inputs

- **Project name** — short slug, used as directory name and tmux session suffix (e.g. `agent`, `web1`)
- **Hostname** — DNS name or IP of the target server
- **User** — SSH user on the target (often `root` or a named admin user)
- **Reference name** — alias the user wants to use in conversation (e.g. "Agent"); defaults to project name
- **How will the project's pubkey reach the target?** Same conversational shape as the relay install. Ask which of these applies — the user shouldn't have to know upfront:
  - **A. Manual paste** — print the pubkey, instruct them to add it to `<user>@<hostname>:~/.ssh/authorized_keys` themselves
  - **B. Password auth** — the user has a root/admin password for the target; the relay deploys the pubkey via `sshpass` for one connection, then everything after is key-only
  - **C. Reuse another project's access** — the relay already has SSH access to this target (or to a host that can reach it) via an existing project's key; use that to deploy the new pubkey
  - **D. Defer** — provision the workspace only, the user will deploy the key later

For multi-host projects, ask the question per host. For most projects there's just one host.

### Steps

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
7. **Deploy the pubkey to the target** — branch on the auth method the user picked in the Inputs phase:

   - **A. Manual paste**
     Print the pubkey block (`cat /home/claude/<project>/key.pub`) and instruct the user to add it to `<user>@<hostname>:~/.ssh/authorized_keys` themselves. Wait for them to confirm they've done it before moving to step 8. Example output:
     ```
     ✅ Project '<project>' provisioned. Paste this on <hostname> as <user>:

         <pubkey contents>

     Reply when it's in place and I'll verify the connection.
     ```

   - **B. Password auth** (`sshpass`)
     ```bash
     # Install sshpass on the relay if missing
     command -v sshpass >/dev/null 2>&1 || apt-get install -y sshpass

     PUBKEY=$(sudo cat /home/claude/<project>/key.pub)
     SSHPASS="<password>" sshpass -e ssh -T \
       -o StrictHostKeyChecking=no -o PreferredAuthentications=password \
       -o PubkeyAuthentication=no -o ConnectTimeout=10 \
       <user>@<hostname> \
       "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
        grep -qxF \"\$PUBKEY\" ~/.ssh/authorized_keys 2>/dev/null \
          || echo \"\$PUBKEY\" >> ~/.ssh/authorized_keys && \
        chmod 600 ~/.ssh/authorized_keys && echo deployed"
     ```
     Never write the password to disk; pass it via environment only. After this one connection, every subsequent SSH from the project uses the key.

   - **C. Reuse another project's access**
     Ask the user which existing project's key has access to the target. Then:
     ```bash
     PUBKEY=$(sudo cat /home/claude/<new-project>/key.pub)
     sudo -u claude ssh -T \
       -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
       -i /home/claude/<existing-project>/key <user>@<hostname> \
       "grep -qxF '$PUBKEY' ~/.ssh/authorized_keys 2>/dev/null \
          || echo '$PUBKEY' >> ~/.ssh/authorized_keys && echo deployed"
     ```

   - **D. Defer**
     Print the pubkey, tell the user the workspace is ready, skip steps 8 and 9, and report that they can run `claude-remote start <project>` once they've deployed the key themselves.

8. **Verify the new key works** (modes A/B/C only):
   ```bash
   sudo -u claude ssh -T -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
     -i /home/claude/<project>/key <user>@<hostname> 'hostname; whoami; echo ok'
   ```
   Should print the target's hostname, the SSH user, and `ok`. If it fails:
   - Mode A → user hasn't pasted yet, or pasted into the wrong file. Surface the error verbatim.
   - Mode B → password may have been wrong, or sshd disallows root password auth. Suggest checking `/etc/ssh/sshd_config` (`PermitRootLogin`, `PasswordAuthentication`) and re-running.
   - Mode C → the chosen existing project may not actually have access to this target. Verify with `claude-remote status <existing-project>` and the relay's logs.

9. **Hand off** to the user:
   ```
   ✅ Project '<project>' provisioned and verified.
   Session label: 🛠️ 🌐  [<project>]  Sysadmin

   Start the session:    claude-remote start <project>
   Change the label:     claude-remote rename <project> "<new label>"
   ```

## Key gotchas

1. **SSH must use** `-T -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10` in scripts. Without these it hangs.
2. **Pre-authorize workspace trust** — Claude sits at the trust dialog otherwise. Set `hasTrustDialogAccepted: true` in `~/.claude.json`.
3. **`claude remote-control`** is a positional subcommand, not a `--remote-control` flag.
4. **User-level systemd services** need `--user` on both `systemctl` and `journalctl`. The bundled `server-ssh` skill knows this — pass it along in the project's `CLAUDE.md` if relevant.

## Hard rules

- Never overwrite an existing project's `key` / `key.pub` without explicit confirmation. If the project dir exists, ask before proceeding.
- Never paste a project's private `key` anywhere. Only `key.pub` goes on target servers.
- Never SSH into the target server from this skill except for the one-shot key deployment (step 7, modes B/C) and the immediate verification (step 8). The ongoing operational SSH is the project Claude's job once its session is running.
- **Never write a password to disk.** Pass passwords through environment variables (`SSHPASS=...`) for a single command invocation, never via temp files or persistent storage.
- **Never reuse password auth after the key is in place.** Once mode B has deployed a key, every further connection must use the key with `BatchMode=yes -o PasswordAuthentication=no`.
