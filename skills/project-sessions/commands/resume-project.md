---
description: Resume the latest session for a relay project
argument-hint: <project-name>
allowed-tools: Bash
---

Resume the relay project session named "$ARGUMENTS".

If `$ARGUMENTS` is empty, first run `claude-remote list` to show available projects and ask the user which one to resume. Then call `claude-remote resume <name>`.

Resuming a project:
- Marks desired_state=running in the state file
- Finds the most recently modified session file for the project's workspace and launches `claude -r <session-id> --remote-control -n "<label>"` inside tmux — the prior conversation reattaches with history intact
- Once running, the cron reconciler will resume it if it ever crashes
- Falls back to a fresh `start` if no prior session exists on disk

After it starts, briefly tell the user the session is back up and they can reconnect via Remote Control from their phone — the picker should show the same labelled session with its prior history.
