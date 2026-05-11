---
description: Show detailed status for a relay project session
argument-hint: <project-name>
allowed-tools: Bash
---

Show the status of relay project "$ARGUMENTS".

Run `claude-relay status $ARGUMENTS` and present the output. If `$ARGUMENTS` is empty, fall back to `claude-relay list` and offer the user a project to drill into.

Detailed status includes: project name, directory, tmux session name, desired vs actual state, last started/stopped/reconciled timestamps. Surface any anomalies (e.g. last_reconciled within the last hour suggests recent crash recovery).
