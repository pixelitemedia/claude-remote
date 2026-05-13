#!/usr/bin/env bash
# bootstrap.sh — one-time relay VPS setup. Idempotent; safe to re-run.
# Must be run as root.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "bootstrap.sh must be run as root" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_USER="claude"
CLAUDE_HOME="/home/${CLAUDE_USER}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

#------------------------------------------------------------------------------
# Arg parsing
#------------------------------------------------------------------------------
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help)
      cat <<EOF
Usage: bootstrap.sh [-y|--yes]

  -y, --yes   Skip the interactive lockout-risk confirmation.
              Use only after verifying root has a working SSH key.
EOF
      exit 0 ;;
    *) die "unknown argument: $arg (try --help)" ;;
  esac
done

#------------------------------------------------------------------------------
# Pre-flight: SSH key sanity check — must run BEFORE we change anything
#------------------------------------------------------------------------------
log "Pre-flight: checking root SSH keys"
AUTH_FILE="/root/.ssh/authorized_keys"
if [[ ! -s "$AUTH_FILE" ]]; then
  die "$AUTH_FILE is missing or empty.
       This bootstrap disables SSH password auth — you will be LOCKED OUT.
       Add at least one valid SSH public key for root before re-running:
           mkdir -p /root/.ssh && chmod 700 /root/.ssh
           echo 'ssh-ed25519 AAAA... your-key' >> $AUTH_FILE
           chmod 600 $AUTH_FILE"
fi
if ! ssh-keygen -l -f "$AUTH_FILE" >/dev/null 2>&1; then
  die "$AUTH_FILE failed validation (ssh-keygen -l).
       Open it and confirm each line is a valid SSH public key."
fi
KEY_COUNT=$(ssh-keygen -l -f "$AUTH_FILE" 2>/dev/null | wc -l | tr -d ' ')
ok "$AUTH_FILE has $KEY_COUNT valid key(s)"

#------------------------------------------------------------------------------
# Confirmation — make sure the operator knows what's changing
#------------------------------------------------------------------------------
if [[ $ASSUME_YES -ne 1 ]]; then
  cat >&2 <<EOF

This bootstrap will:
  • Disable SSH password authentication (key-only login)
  • Set PermitRootLogin to "prohibit-password"
  • Enable UFW (allow port 22 only)
  • Install fail2ban + unattended-upgrades
  • Create 'claude' user with passwordless sudo and mirror root's authorized_keys

If the key(s) in $AUTH_FILE do not actually let you log in, you will be
LOCKED OUT after sshd reloads. Test from a SECOND terminal first:
    ssh -i <your-private-key> root@<this-host> 'echo ok'

EOF
  if [[ -t 0 ]]; then
    read -r -p "Proceed? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted by user."
  else
    die "Non-interactive run without --yes. Re-run with -y to acknowledge the lockout risk."
  fi
fi

#------------------------------------------------------------------------------
# 1. Create claude user with passwordless sudo
#------------------------------------------------------------------------------
log "Ensuring ${CLAUDE_USER} user exists"
if ! id -u "$CLAUDE_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$CLAUDE_USER"
  ok "Created user ${CLAUDE_USER}"
else
  ok "User ${CLAUDE_USER} already exists"
fi

SUDOERS_FILE="/etc/sudoers.d/${CLAUDE_USER}"
if [[ ! -f "$SUDOERS_FILE" ]]; then
  echo "${CLAUDE_USER} ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS_FILE"
  chmod 0440 "$SUDOERS_FILE"
  ok "Granted passwordless sudo to ${CLAUDE_USER}"
fi

#------------------------------------------------------------------------------
# 2. Copy root's authorized_keys to claude user
#------------------------------------------------------------------------------
log "Mirroring root's authorized_keys to ${CLAUDE_USER}"
install -d -o "$CLAUDE_USER" -g "$CLAUDE_USER" -m 0700 "${CLAUDE_HOME}/.ssh"
if [[ -f /root/.ssh/authorized_keys ]]; then
  install -o "$CLAUDE_USER" -g "$CLAUDE_USER" -m 0600 \
    /root/.ssh/authorized_keys "${CLAUDE_HOME}/.ssh/authorized_keys"
  ok "authorized_keys mirrored"
else
  warn "/root/.ssh/authorized_keys missing — skipping mirror"
fi

#------------------------------------------------------------------------------
# 3. Install packages: ufw, fail2ban, unattended-upgrades, tmux
#------------------------------------------------------------------------------
log "Installing security packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ufw fail2ban unattended-upgrades tmux >/dev/null
ok "Packages installed"

#------------------------------------------------------------------------------
# 4. UFW: allow port 22 only
#------------------------------------------------------------------------------
log "Configuring UFW (port 22 only)"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp >/dev/null
ufw --force enable >/dev/null
ok "UFW active"

#------------------------------------------------------------------------------
# 5. fail2ban: enable
#------------------------------------------------------------------------------
log "Enabling fail2ban"
systemctl enable --now fail2ban >/dev/null 2>&1 || true
ok "fail2ban enabled"

#------------------------------------------------------------------------------
# 6. Unattended upgrades
#------------------------------------------------------------------------------
log "Enabling unattended-upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
ok "Unattended upgrades enabled"

#------------------------------------------------------------------------------
# 7. 1GB swap if none
#------------------------------------------------------------------------------
log "Checking swap"
if [[ "$(swapon --show | wc -l)" -eq 0 ]]; then
  fallocate -l 1G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  if ! grep -q '^/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
  ok "1GB swap created"
else
  ok "Swap already present"
fi

#------------------------------------------------------------------------------
# 8. SSH hardening: key-only, no root password login
#------------------------------------------------------------------------------
log "Hardening sshd"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-claude-remote.conf"
cat > "$SSHD_DROPIN" <<'EOF'
PasswordAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF
chmod 0644 "$SSHD_DROPIN"
if sshd -t 2>/dev/null; then
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  ok "sshd hardened and reloaded"
else
  warn "sshd config test failed — leaving service untouched"
  rm -f "$SSHD_DROPIN"
fi

#------------------------------------------------------------------------------
# 9. Install claude.sh
#------------------------------------------------------------------------------
log "Linking claude.sh into /usr/local/bin"
if [[ -f "${SCRIPT_DIR}/claude.sh" ]]; then
  chmod +x "${SCRIPT_DIR}/claude.sh"
  # Replace any prior copy or symlink with a fresh symlink so edits in the
  # skill repo flow through without re-running bootstrap.
  ln -sfn "${SCRIPT_DIR}/claude.sh" /usr/local/bin/claude.sh
  ok "claude.sh -> ${SCRIPT_DIR}/claude.sh"
else
  warn "${SCRIPT_DIR}/claude.sh not found — install it manually"
fi

#------------------------------------------------------------------------------
# 10. Pre-authorize workspace trust + allowBypassPermissions for root
#------------------------------------------------------------------------------
log "Configuring root Claude trust + permissions"

# Pre-trust /root workspace in ~/.claude.json
ROOT_CLAUDE_JSON="/root/.claude.json"
if [[ ! -f "$ROOT_CLAUDE_JSON" ]]; then
  echo '{}' > "$ROOT_CLAUDE_JSON"
fi
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY'
import json, pathlib
p = pathlib.Path("/root/.claude.json")
data = json.loads(p.read_text() or "{}")
projects = data.setdefault("projects", {})
projects.setdefault("/root", {})["hasTrustDialogAccepted"] = True
p.write_text(json.dumps(data, indent=2))
PY
  ok "Pre-authorized /root workspace trust"
else
  warn "python3 missing — could not patch /root/.claude.json"
fi

# allowBypassPermissions for root Claude
install -d -m 0700 /root/.claude
ROOT_SETTINGS="/root/.claude/settings.json"
if [[ ! -f "$ROOT_SETTINGS" ]]; then
  echo '{}' > "$ROOT_SETTINGS"
fi
if command -v python3 >/dev/null 2>&1; then
  python3 - <<'PY'
import json, pathlib
p = pathlib.Path("/root/.claude/settings.json")
data = json.loads(p.read_text() or "{}")
data["allowBypassPermissions"] = True
p.write_text(json.dumps(data, indent=2))
PY
  ok "allowBypassPermissions enabled for root"
fi

# allowBypassPermissions for the claude user too. Without this, every project
# Claude session prompts for every Bash/Edit operation — unworkable from
# Remote Control on a phone where --dangerously-skip-permissions is blocked.
# The claude user is already sandboxed by per-project SSH key scoping, so
# bypassing prompts mirrors the trust model already in place.
install -d -o "$CLAUDE_USER" -g "$CLAUDE_USER" -m 0700 "${CLAUDE_HOME}/.claude"
CLAUDE_USER_SETTINGS="${CLAUDE_HOME}/.claude/settings.json"
if ! sudo -u "$CLAUDE_USER" test -f "$CLAUDE_USER_SETTINGS"; then
  sudo -u "$CLAUDE_USER" bash -c "echo '{}' > $CLAUDE_USER_SETTINGS"
fi
if command -v python3 >/dev/null 2>&1; then
  sudo -u "$CLAUDE_USER" python3 - <<PY
import json, pathlib
p = pathlib.Path("$CLAUDE_USER_SETTINGS")
data = json.loads(p.read_text() or "{}")
data["allowBypassPermissions"] = True
p.write_text(json.dumps(data, indent=2))
PY
  ok "allowBypassPermissions enabled for ${CLAUDE_USER}"
fi

#------------------------------------------------------------------------------
# 11. Starter /root/CLAUDE.md
#------------------------------------------------------------------------------
log "Writing /root/CLAUDE.md"
if [[ ! -f /root/CLAUDE.md ]]; then
  cat > /root/CLAUDE.md <<'EOF'
# Root Claude — relay VPS

You are root Claude on the relay. Your job is to manage the relay itself,
provision new project workspaces under /home/claude/<project>/, and manage
the lifecycle of project Claude sessions.

## At session start: check system alerts

Before the first user message of a session, read `/root/.claude/system-alerts.md`
if it exists. The disk-monitor cron writes there when any partition crosses
90% usage. If there are recent entries (today's date), surface them to the
user as a leading note. After they're acknowledged, the user can clear the
file with `> /root/.claude/system-alerts.md` (or let it grow — it's append-only).

## Skills you have

- `server-sysadmin-bootstrap` — one-time relay setup (already run)
- `server-sysadmin` — provision a new project for a target server
- `project-sessions` — manage running project sessions (start/stop/reconcile)

## Common tasks

- List projects + state: `/list-projects` or `claude-remote list`
- Start (resume latest session): `/start-project <name>` or `claude-remote start <name>`
- Stop a project: `/stop-project <name>` or `claude-remote stop <name>`
- Reconcile drift: `/reconcile-projects` or `claude-remote reconcile`
- Provision a new project: invoke the `server-sysadmin` skill
- Relay health: `claude-remote health` (disk, session counts, alerts)

## Root session itself

Your tmux session (claude-root) is opt-in persistent. To enroll in cron's
auto-resume so a crash brings you back with history intact:

    claude-remote root start         # or 'resume' if you have a prior session

To stop and disenroll: `claude-remote root stop`. Manual attach (no state
tracking): `claude.sh`.

## Hard rules

- Do NOT SSH into target servers from the root session — that is the project
  Claude's job, using its own per-project key.
- Stop the root session when not actively provisioning or managing.
EOF
  ok "/root/CLAUDE.md written"
else
  ok "/root/CLAUDE.md already exists — not overwriting"
fi

#------------------------------------------------------------------------------
# 12. Ensure /home/claude exists with .claude dir for trust state
#------------------------------------------------------------------------------
install -d -o "$CLAUDE_USER" -g "$CLAUDE_USER" -m 0750 "${CLAUDE_HOME}/.claude"
if [[ ! -f "${CLAUDE_HOME}/.claude.json" ]]; then
  sudo -u "$CLAUDE_USER" bash -c 'echo "{}" > ~/.claude.json'
fi

#------------------------------------------------------------------------------
# 13. Install Claude Code CLI for the claude user
#------------------------------------------------------------------------------
# The native installer is user-scoped (installs into ~/.local/share/claude/).
# A `claude install` run as root does NOT make the binary available to the
# claude user — and on multi-user hosts like this relay, that silently breaks
# every project session. So we install per-user, here.
#
# On low-RAM VPSes (<1GB) the installer can OOM-kill itself during extraction
# (it briefly maps ~70GB of virtual address space). To avoid that, if root
# already has a copy of the binary we just clone it across — a file copy
# doesn't blow the memory budget. Falls back to the official installer if
# root doesn't have one yet.

log "Installing Claude Code for ${CLAUDE_USER} user"
CLAUDE_BIN_DIR="${CLAUDE_HOME}/.local/bin"
CLAUDE_BIN="${CLAUDE_BIN_DIR}/claude"
CLAUDE_VERSIONS_DIR="${CLAUDE_HOME}/.local/share/claude/versions"

if sudo -u "$CLAUDE_USER" test -x "$CLAUDE_BIN"; then
  ok "claude already installed for ${CLAUDE_USER} ($(sudo -u "$CLAUDE_USER" "$CLAUDE_BIN" --version 2>/dev/null || echo unknown))"
elif [[ -d /root/.local/share/claude/versions ]] \
     && [[ -n "$(ls -1 /root/.local/share/claude/versions/ 2>/dev/null)" ]]; then
  ROOT_VERSION=$(ls -1 /root/.local/share/claude/versions/ | sort -V | tail -1)
  ROOT_BIN="/root/.local/share/claude/versions/${ROOT_VERSION}"
  if [[ -x "$ROOT_BIN" ]]; then
    log "Copying root's claude $ROOT_VERSION to ${CLAUDE_USER} (skips OOM-prone re-install)"
    install -d -o "$CLAUDE_USER" -g "$CLAUDE_USER" -m 0755 "$CLAUDE_BIN_DIR" "$CLAUDE_VERSIONS_DIR"
    install -o "$CLAUDE_USER" -g "$CLAUDE_USER" -m 0755 \
      "$ROOT_BIN" "${CLAUDE_VERSIONS_DIR}/${ROOT_VERSION}"
    sudo -u "$CLAUDE_USER" ln -sfn "${CLAUDE_VERSIONS_DIR}/${ROOT_VERSION}" "$CLAUDE_BIN"
    ok "claude $ROOT_VERSION installed for ${CLAUDE_USER}"
  else
    warn "/root/.local/share/claude/versions/${ROOT_VERSION} is not executable — falling back to installer"
  fi
fi

if ! sudo -u "$CLAUDE_USER" test -x "$CLAUDE_BIN"; then
  log "Running official claude installer as ${CLAUDE_USER}"
  if [[ "$(awk '/MemTotal/ {print $2}' /proc/meminfo)" -lt 768000 ]]; then
    warn "RAM under ~750MB — installer may OOM. If it fails, install claude for root first, then re-run this bootstrap (it will then clone root's copy)."
  fi
  sudo -u "$CLAUDE_USER" bash -lc 'curl -fsSL https://claude.ai/install.sh | bash' || true
  if sudo -u "$CLAUDE_USER" test -x "$CLAUDE_BIN"; then
    ok "claude installed for ${CLAUDE_USER}"
  else
    warn "claude install for ${CLAUDE_USER} did not produce $CLAUDE_BIN — install manually before starting project sessions"
  fi
fi

#------------------------------------------------------------------------------
# 14. Chain into project-sessions install (if the sibling skill is present)
#------------------------------------------------------------------------------
# Skill layout: skills/server-sysadmin-bootstrap/scripts/bootstrap.sh
# Sibling:     skills/project-sessions/scripts/claude-remote
SKILLS_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
RELAY_CLI="${SKILLS_DIR}/project-sessions/scripts/claude-remote"

if [[ -x "$RELAY_CLI" ]]; then
  log "Chaining into project-sessions install"
  "$RELAY_CLI" install
  ok "project-sessions installed"
else
  warn "project-sessions skill not found alongside this one — skipping claude-remote install"
  echo "    Expected at: $RELAY_CLI"
fi

#------------------------------------------------------------------------------
# 15. Symlink operational helper scripts into /usr/local/bin
#------------------------------------------------------------------------------
log "Linking operational helper scripts"
for helper in check-disk-alerts.sh claude-update.sh; do
  src="${SCRIPT_DIR}/${helper}"
  if [[ -f "$src" ]]; then
    chmod +x "$src"
    ln -sfn "$src" "/usr/local/bin/${helper}"
    ok "/usr/local/bin/${helper} -> ${src}"
  else
    warn "${src} not found — skipping"
  fi
done

#------------------------------------------------------------------------------
# 16. Logrotate config for /var/log/claude-remote.log
#------------------------------------------------------------------------------
log "Installing logrotate config"
cat > /etc/logrotate.d/claude-remote <<'EOF'
/var/log/claude-remote.log /var/log/claude-update.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
EOF
ok "/etc/logrotate.d/claude-remote installed"

#------------------------------------------------------------------------------
# 17. Cron jobs (reconcile + disk monitor + weekly CLI update)
#------------------------------------------------------------------------------
CRON_RECONCILE='*/5 * * * * /usr/local/bin/claude-remote reconcile'
CRON_DISK='17 */2 * * * /usr/local/bin/check-disk-alerts.sh 90'
CRON_UPDATE='23 4 * * 0 /usr/local/bin/claude-update.sh'

install_cron=0
if [[ $ASSUME_YES -eq 1 ]]; then
  install_cron=1
elif [[ -t 0 ]]; then
  cat <<EOF
Install root crontab entries?
  ${CRON_RECONCILE}     (every 5 min — restart any desired=running project that's down)
  ${CRON_DISK}     (every 2 hours — append to /root/.claude/system-alerts.md if any partition >= 90%)
  ${CRON_UPDATE}    (weekly Sun 04:23 — claude CLI update, skips if any session is running)
EOF
  read -r -p "Install? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] && install_cron=1
fi

if [[ $install_cron -eq 1 ]]; then
  if (crontab -l 2>/dev/null \
        | grep -v 'claude-remote reconcile' \
        | grep -v 'check-disk-alerts.sh' \
        | grep -v 'claude-update.sh'
      echo "$CRON_RECONCILE"
      echo "$CRON_DISK"
      echo "$CRON_UPDATE") | crontab -; then
    ok "Cron entries installed for root"
  else
    warn "Failed to install cron entries — add manually (see above)"
  fi
else
  echo "Skipped cron install. To add later, run:"
  echo "  (crontab -l 2>/dev/null; echo '$CRON_RECONCILE'; echo '$CRON_DISK'; echo '$CRON_UPDATE') | crontab -"
fi

echo
ok "Bootstrap complete."
echo
echo "Next: provision a project. Tell Claude:"
echo "  'provision a new project called <name>, host <hostname>, user <user>'"
