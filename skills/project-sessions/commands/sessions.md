---
description: List prior Claude sessions for a relay project and pick one to resume
argument-hint: <project-name>
allowed-tools: Bash
---

Show the user available Claude sessions for project "$ARGUMENTS" and let them pick one to resume.

1. If `$ARGUMENTS` is empty, first run `claude-remote list` and ask which project they want to look at.
2. Run `claude-remote sessions $ARGUMENTS`. The output is a table:
   - `#`  — list number
   - `ID` — 8-char session id prefix (unique within the project, safe to use as resume target)
   - `WHEN` — last-modified time of the session file
   - `MSGS` — message count in the session log
   - `FIRST USER MESSAGE` — preview of the first user message
3. Present the table cleanly and ask the user which one they'd like to resume.
4. When they pick, call `claude-remote resume $ARGUMENTS <ID>` using the 8-char prefix from the table.
   - This stops the currently-running project session (if any) and starts a new tmux session resuming the chosen Claude session.
   - The Remote Control session label (`🛠️ 🌐  [<project>]  …`) is preserved.

If the table is empty, tell the user there are no prior sessions and offer to start a fresh one with `claude-remote start $ARGUMENTS`.
