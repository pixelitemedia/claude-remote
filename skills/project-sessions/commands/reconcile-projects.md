---
description: Restart any relay projects that should be running but aren't
allowed-tools: Bash
---

Run `claude-remote reconcile` and report what happened.

Reconciliation looks at every project with `desired_state=running` and checks whether its tmux session is actually up. Any that are down get **resumed** — `claude-remote` looks up the latest session file for the workspace and invokes `claude -r <session-id> --remote-control -n "<label>"` so the user's prior conversation is restored, not lost. If no prior session exists on disk, it falls back to a fresh start.

If anything was restarted, list which projects and suggest the user check `/var/log/claude-remote.log` if it's happening repeatedly (could indicate a crash loop). If nothing was restarted, just say "all healthy".
