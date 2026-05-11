---
description: Stop a relay project session
argument-hint: <project-name>
allowed-tools: Bash
---

Stop the relay project session named "$ARGUMENTS".

If `$ARGUMENTS` is empty, run `claude-remote list` first, then ask which project to stop. Confirm with the user before stopping — killing the tmux session interrupts any active phone connection to that project.

Then call `claude-remote stop <name>`.

This:
- Marks desired_state=stopped in the state file (so cron reconciler will NOT auto-restart it)
- Kills the tmux session

To bring it back, use `/start-project <name>`.
