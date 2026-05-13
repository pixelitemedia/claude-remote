#!/usr/bin/env bash
# install.sh — one-liner relay bootstrap.
#
# Run on a fresh root login on the relay VPS:
#
#   curl -fsSL https://raw.githubusercontent.com/pixelitemedia/claude-remote/main/install.sh | bash
#
# Or for an interactive install (prompts for lockout-risk confirmation):
#
#   curl -fsSL https://raw.githubusercontent.com/pixelitemedia/claude-remote/main/install.sh \
#     | INTERACTIVE=1 bash

set -euo pipefail

INSTALL_DIR=${INSTALL_DIR:-/root/claude-remote}
REPO_URL=${REPO_URL:-https://github.com/pixelitemedia/claude-remote.git}
BRANCH=${BRANCH:-main}
INTERACTIVE=${INTERACTIVE:-0}

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "install.sh must be run as root"

#------------------------------------------------------------------------------
# Pre-flight: root must already have a working SSH key (or bootstrap will lock
# the user out). Same check bootstrap.sh does, surfaced earlier for clarity.
#------------------------------------------------------------------------------
log "Pre-flight: checking root SSH key"
AUTH=/root/.ssh/authorized_keys
if [[ ! -s "$AUTH" ]] || ! ssh-keygen -l -f "$AUTH" >/dev/null 2>&1; then
  die "$AUTH is missing, empty, or invalid.
       Add a working SSH public key for root BEFORE running this installer:
           mkdir -p /root/.ssh && chmod 700 /root/.ssh
           echo 'ssh-ed25519 AAAA... your-key' >> $AUTH
           chmod 600 $AUTH
       Confirm you can SSH in with it from another terminal, then re-run."
fi
ok "root has a valid SSH key on file"

#------------------------------------------------------------------------------
# Required packages for the cloning + Claude installer steps
#------------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  log "Installing prerequisites (git, curl)"
  apt-get update -qq
  apt-get install -y -qq git curl >/dev/null
fi

#------------------------------------------------------------------------------
# Clone / update the relay skills repo
#------------------------------------------------------------------------------
if [[ -d "$INSTALL_DIR/.git" ]]; then
  log "Updating existing checkout at $INSTALL_DIR"
  git -C "$INSTALL_DIR" fetch --quiet origin "$BRANCH"
  git -C "$INSTALL_DIR" reset --hard "origin/$BRANCH" --quiet
else
  log "Cloning $REPO_URL into $INSTALL_DIR"
  git clone --quiet --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi
ok "Repo present at $INSTALL_DIR"

#------------------------------------------------------------------------------
# Install Claude Code CLI for root if missing
#------------------------------------------------------------------------------
if [[ ! -x /root/.local/bin/claude ]]; then
  log "Installing Claude Code CLI for root"
  curl -fsSL https://claude.ai/install.sh | bash
  export PATH="/root/.local/bin:$PATH"
  ok "Claude Code installed for root ($(/root/.local/bin/claude --version 2>/dev/null || echo unknown))"
else
  ok "Claude Code already installed for root ($(/root/.local/bin/claude --version 2>/dev/null || echo unknown))"
fi

#------------------------------------------------------------------------------
# Run the relay bootstrap. -y unless INTERACTIVE=1.
#------------------------------------------------------------------------------
log "Running bootstrap"
if [[ "$INTERACTIVE" == "1" ]]; then
  bash "$INSTALL_DIR/skills/server-sysadmin-bootstrap/scripts/bootstrap.sh"
else
  bash "$INSTALL_DIR/skills/server-sysadmin-bootstrap/scripts/bootstrap.sh" -y
fi

echo
ok "Relay is bootstrapped."
echo "Next steps:"
echo "  • Start Claude Code as root: claude.sh"
echo "  • Or via the new stateful manager: claude-remote root resume"
echo "  • Provision a target server: tell Claude 'provision a new project ...'"
