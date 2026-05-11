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
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-claude-relay.conf"
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

#------------------------------------------------------------------------------
# 11. Starter /root/CLAUDE.md
#------------------------------------------------------------------------------
log "Writing /root/CLAUDE.md"
if [[ ! -f /root/CLAUDE.md ]]; then
  cat > /root/CLAUDE.md <<'EOF'
# Root Claude — relay VPS

You are root Claude on the relay. Your job is to manage the relay itself and
provision new project workspaces under /home/claude/<project>/.

## Common tasks

- Bootstrap / re-run setup: `bash <skill>/scripts/bootstrap.sh`
- List sessions: `claude.sh list`
- Start/stop project sessions: `claude.sh <project>` / `claude.sh <project> stop`
- Provision a new project: invoke the `server-sysadmin` skill's provisioning flow

## Hard rules

- Do NOT SSH into target servers from the root session — that's the project
  Claude's job, using its own per-project key.
- Stop the root session when not actively provisioning: `claude.sh stop`.
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

echo
ok "Bootstrap complete."
echo
echo "Next: provision a project. Tell Claude:"
echo "  'provision a new project called <name>, host <hostname>, user <user>'"
