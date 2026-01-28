---
name: ralph
description: Trigger the Ralph Wiggum loop runner from the terminal.
---

When the user runs **/ralph**, do this:

1) Explain that the loop runs from terminal for clean sessions.
2) Tell them to run:
   - `./scripts/ralph/ralph.sh`
3) If they want custom iterations:
   - `./scripts/ralph/ralph.sh --iterations 10`
4) If they want a specific story:
   - `./scripts/ralph/ralph.sh --task-id US-002`

If `state.json.status` is `NEEDS_CLARIFICATION`, answer in `answers.md` and run again.