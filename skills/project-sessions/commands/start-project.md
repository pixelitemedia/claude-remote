---
description: Start a fresh relay project session
argument-hint: <project-name>
allowed-tools: Bash
---

Start a **fresh** relay project session named "$ARGUMENTS". To continue the latest prior session instead, use `/resume-project`.

If `$ARGUMENTS` is empty, first run `claude-remote list` to show available projects and ask the user which one to start. Then call `claude-remote start <name>`.

Starting a project:
- Marks desired_state=running in the state file
- Launches `claude --remote-control -n "<label>"` inside tmux — a brand new session, no prior history
- Once running, the cron reconciler will *resume* it (not fresh-start it) if it ever crashes

After it starts, briefly tell the user the session is up and they can connect via Remote Control from their phone.
