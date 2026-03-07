---
name: ralph
description: Trigger the Ralph Wiggum loop runner from the terminal.
---

When the user runs **/ralph**, do this:

1) Explain that the loop runs from terminal for clean sessions.
2) Tell them to run:
   - `ralph/ralph.sh`
3) If they want custom iterations:
   - `ralph/ralph.sh --iterations 10`
4) If they want a specific story:
   - `ralph/ralph.sh --task-id US-002`
5) If they want planning mode (generate IMPLEMENTATION_PLAN.md):
   - `ralph/ralph.sh --mode plan`
6) If they want parallel agents:
   - `ralph/ralph-parallel.sh` (reads agent table from ralph/ralph.yaml)
7) If they want background self-improvement:
   - `ralph/ralph-think.sh`

If `state.json.status` is `NEEDS_CLARIFICATION`, answer in `answers.md` and run again.
