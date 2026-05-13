---
description: Report relay health — session-history disk usage, partitions, alerts, cron status
allowed-tools: Bash
---

Run `claude-remote health` and present the result.

Surface to the user, in order:
1. Any items from "System alerts (today, N)" — these mean the disk-monitor cron flagged something within the last 24 hours
2. Any partition row that's yellow-highlighted (≥ 80% used)
3. Any "WORKSPACE" row in the session-history table that's yellow (≥ 200 sessions or ≥ 1G in size) — advisory only, no automatic action
4. Any missing cron entries (reconcile, disk-alert, weekly update)

If everything is green, say "all healthy" and stop. Otherwise, briefly explain each concern and offer concrete next steps (e.g. "I can help you clear old session histories for project X" or "I can re-run bootstrap to install missing crons"). Do not act without the user agreeing.
