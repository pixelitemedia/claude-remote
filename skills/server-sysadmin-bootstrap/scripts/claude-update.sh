#!/usr/bin/env bash
# claude-update.sh — weekly Claude Code CLI updater for the relay.
#
# Runs from cron (Sun ~04:23 by default). For each of {root, claude} users,
# re-runs the official installer if no active tmux sessions exist for them.
# The official installer is idempotent and lands the latest version.
#
# Skipped automatically if any session is running, so we never yank a binary
# out from under a live Remote Control connection.

set -euo pipefail

LOG=/var/log/claude-update.log
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(ts)" "$*" >> "$LOG" 2>/dev/null || true; }

mkdir -p "$(dirname "$LOG")"
touch "$LOG"
chmod 0640 "$LOG" 2>/dev/null || true

# Check root tmux
if tmux ls 2>/dev/null | grep -qE '^claude-'; then
  log "skipped: root tmux session(s) running"
  exit 0
fi

# Check claude user tmux
if sudo -u claude tmux ls 2>/dev/null | grep -qE '^claude-'; then
  log "skipped: claude-user tmux session(s) running"
  exit 0
fi

log "starting update"

# Update root's claude
if curl -fsSL https://claude.ai/install.sh | bash >> "$LOG" 2>&1; then
  v=$(/root/.local/bin/claude --version 2>/dev/null || echo unknown)
  log "root: claude version $v"
else
  log "root: installer failed"
fi

# Update claude user's claude
if sudo -u claude bash -lc 'curl -fsSL https://claude.ai/install.sh | bash' >> "$LOG" 2>&1; then
  v=$(sudo -u claude /home/claude/.local/bin/claude --version 2>/dev/null || echo unknown)
  log "claude user: claude version $v"
else
  log "claude user: installer failed"
fi

log "done"
