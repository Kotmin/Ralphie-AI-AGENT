---
name: create-prd
description: Use when the user wants to create a PRD, scaffold a task list, write requirements, start a new ralph project, or generate a PRD.md file. Examples: "create a prd", "scaffold my task list", "write requirements for my project", "create task list for ralph".
version: 1.0.0
---

# create-prd Skill

Interactively scaffold a `PRD.md` for use with Ralph.

## When This Skill Applies

- "create a prd"
- "scaffold my tasks"
- "write a task list for ralph"
- "generate requirements"
- "create task list"

## Parameters (parsed from user message)

- `[output-path]` — where to write the PRD (default: `PRD.md` at project root)

## Execution Steps

### 1. Gather information

Ask the user (in a single message, as a numbered list):

1. What is the project name?
2. What is the project's purpose in one sentence?
3. List the features or tasks you need implemented (one per line).
4. What test/build command should Ralph run to validate work? (leave blank if unsure)

Wait for answers before proceeding.

### 2. Validate input

- At least one task must be provided
- Task IDs will be auto-assigned as `US-001`, `US-002`, etc.

### 3. Generate PRD.md

Write `PRD.md` (or `[output-path]` if specified) using this structure:

```
# PRD.md — <project name>

## Purpose
<one-sentence purpose>

---

## Core Principles
- Correctness over cleverness
- Stop instead of guessing
- PRD.md is the single source of truth

---

## Task List

### [ ] US-001: <task 1 title>

**Description**
<brief description>

**Acceptance Criteria**
- Implementation complete
- Tests pass

---

### [ ] US-002: <task 2 title>
...
```

### 4. Confirm before writing

Show a preview of the first 2 tasks and ask: "Write this PRD to `PRD.md`? (yes/no)"

Do NOT write the file until the user confirms.

### 5. Post-write instructions

After writing, print:

```
PRD.md written. Next steps:
  1. Review and edit PRD.md as needed
  2. Generate a plan:  ralph/ralph.sh --mode plan
  3. Run the build:    ralph/ralph.sh --iterations 3
```

## Key Rules

- Never overwrite an existing `PRD.md` without explicit confirmation
- Task IDs must be sequential and unique
- Keep task descriptions short — Claude implements exactly what is written
