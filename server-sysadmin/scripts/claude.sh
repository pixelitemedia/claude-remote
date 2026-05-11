#!/usr/bin/env bash
# claude.sh — tmux launcher for relay Claude sessions.
#
# Usage:
#   claude.sh                   # Root session (start or reattach)
#   claude.sh stop              # Stop root session
#   claude.sh status            # Status of root session
#   claude.sh <project>         # Project session (start or reattach)
#   claude.sh <project> stop    # Stop project session
#   claude.sh <project> status  # Status of project session
#   claude.sh list              # List all sessions and available projects

set -euo pipefail

CLAUDE_USER="claude"
CLAUDE_HOME="/home/${CLAUDE_USER}"
ROOT_SESSION="claude-root"
PROJECT_PREFIX="claude-"

die() { echo "error: $*" >&2; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "claude.sh must be run as root"
}

session_exists() {
  local owner="$1" name="$2"
  if [[ "$owner" == "root" ]]; then
    tmux has-session -t "$name" 2>/dev/null
  else
    sudo -u "$owner" tmux has-session -t "$name" 2>/dev/null
  fi
}

start_root() {
  if session_exists root "$ROOT_SESSION"; then
    echo "Reattaching root session ($ROOT_SESSION)"
  else
    echo "Starting root session ($ROOT_SESSION)"
    tmux new-session -d -s "$ROOT_SESSION" -c /root \
      "claude --dangerously-skip-permissions remote-control"
  fi
  exec tmux attach-session -t "$ROOT_SESSION"
}

stop_root() {
  if session_exists root "$ROOT_SESSION"; then
    tmux kill-session -t "$ROOT_SESSION"
    echo "Stopped $ROOT_SESSION"
  else
    echo "No root session running"
  fi
}

status_root() {
  if session_exists root "$ROOT_SESSION"; then
    echo "Root session: RUNNING ($ROOT_SESSION)"
  else
    echo "Root session: stopped"
  fi
}

project_dir() {
  echo "${CLAUDE_HOME}/$1"
}

project_session() {
  echo "${PROJECT_PREFIX}$1"
}

start_project() {
  local project="$1"
  local dir; dir="$(project_dir "$project")"
  local session; session="$(project_session "$project")"

  [[ -d "$dir" ]] || die "project '$project' not found at $dir"

  if session_exists "$CLAUDE_USER" "$session"; then
    echo "Reattaching project session ($session)"
  else
    echo "Starting project session ($session) for $project"
    sudo -u "$CLAUDE_USER" tmux new-session -d -s "$session" -c "$dir" \
      "claude remote-control"
  fi
  exec sudo -u "$CLAUDE_USER" tmux attach-session -t "$session"
}

stop_project() {
  local project="$1"
  local session; session="$(project_session "$project")"
  if session_exists "$CLAUDE_USER" "$session"; then
    sudo -u "$CLAUDE_USER" tmux kill-session -t "$session"
    echo "Stopped $session"
  else
    echo "No session running for project '$project'"
  fi
}

status_project() {
  local project="$1"
  local session; session="$(project_session "$project")"
  if session_exists "$CLAUDE_USER" "$session"; then
    echo "Project '$project': RUNNING ($session)"
  else
    echo "Project '$project': stopped"
  fi
}

cmd_list() {
  echo "Sessions:"
  status_root
  if [[ -d "$CLAUDE_HOME" ]]; then
    local found=0
    for dir in "$CLAUDE_HOME"/*/; do
      [[ -d "$dir" ]] || continue
      local name; name="$(basename "$dir")"
      [[ "$name" == ".ssh" || "$name" == ".claude" || "$name" == ".cache" ]] && continue
      [[ "$name" =~ ^\. ]] && continue
      status_project "$name"
      found=1
    done
    [[ $found -eq 0 ]] && echo "  (no projects in $CLAUDE_HOME)"
  fi
  echo
  echo "Available projects:"
  if [[ -d "$CLAUDE_HOME" ]]; then
    find "$CLAUDE_HOME" -mindepth 1 -maxdepth 1 -type d \
      ! -name '.*' -printf '  %f\n' | sort
  fi
}

#------------------------------------------------------------------------------
# Argument dispatch
#------------------------------------------------------------------------------
require_root

case "${1:-}" in
  "")        start_root ;;
  stop)      stop_root ;;
  status)    status_root ;;
  list)      cmd_list ;;
  *)
    project="$1"
    action="${2:-attach}"
    case "$action" in
      attach) start_project "$project" ;;
      stop)   stop_project "$project" ;;
      status) status_project "$project" ;;
      *) die "unknown action '$action' (expected: stop|status, or no arg to attach)" ;;
    esac
    ;;
esac
