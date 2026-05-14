---
description: List all relay project sessions with their desired and actual states
allowed-tools: Bash
---

Run `claude-remote list` and present the result to the user.

Highlight any rows where DESIRED ≠ ACTUAL:
- `desired=running, actual=stopped` → drift, reconcile will fix this within ~5 minutes
- `desired=stopped, actual=running` → user (or someone) started it manually

If there's any drift, offer to run `/reconcile-projects` to fix it now.
