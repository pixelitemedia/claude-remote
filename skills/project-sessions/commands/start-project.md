---
description: Start (or resume) a relay project session
argument-hint: <project-name>
allowed-tools: Bash
---

Start the relay project session named "$ARGUMENTS".

If `$ARGUMENTS` is empty, first run `claude-relay list` to show available projects and ask the user which one to start. Then call `claude-relay start <name>`.

Starting a project:
- Marks desired_state=running in the state file
- Launches `claude --continue remote-control` inside tmux so the **latest** Claude session for that project resumes with full history
- Once running, the cron reconciler will restart it if it ever crashes

After it starts, briefly tell the user the session is up and they can connect via Remote Control from their phone.
