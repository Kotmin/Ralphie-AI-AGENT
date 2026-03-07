# Ralph — Autonomous Claude Loop Runner

Minimal, production-oriented automation loop for Claude Code. Each iteration runs Claude
in a fresh headless process with no chat history. Persistent state lives in tracking files;
work happens in git worktrees.

## End-to-End: First Project

### Step 1 — Get Ralph (one-time)

```bash
git clone https://github.com/your-org/ralphie-ai-agent ~/ralphie-ai-agent
```

### Step 2 — Make the install skill globally available (one-time)

This lets you say **"install ralph into /path/to/project"** from any Claude Code session,
not just when you have the ralph repo open.

```bash
RALPH_REPO="$HOME/ralphie-ai-agent"   # adjust if you cloned elsewhere

mkdir -p ~/.claude/plugins/marketplaces/local/plugins/ralph/.claude-plugin
mkdir -p ~/.claude/plugins/marketplaces/local/plugins/ralph/skills/install

cat > ~/.claude/plugins/marketplaces/local/plugins/ralph/.claude-plugin/plugin.json <<'EOF'
{
  "name": "ralph",
  "description": "Install Ralph autonomous loop runner into any project",
  "author": { "name": "you" }
}
EOF

cp "$RALPH_REPO/ralph/skills/install/SKILL.md" \
   ~/.claude/plugins/marketplaces/local/plugins/ralph/skills/install/SKILL.md

# Patch the skill with the absolute script path (no manual edits needed after this)
sed -i "s|ralph/skills/install/install.sh|$RALPH_REPO/ralph/skills/install/install.sh|g" \
   ~/.claude/plugins/marketplaces/local/plugins/ralph/skills/install/SKILL.md
```

> The `install.sh` script auto-detects its own location, so you never need to edit the
> script itself — only the path in the skill's instruction file.

### Step 3 — Install Ralph into your project

Open Claude Code in **any** project, then say:

```
install ralph into /absolute/path/to/my-project
```

Claude runs `install.sh`, copies the `ralph/` directory, and prints next steps.

### Step 4 — Configure

```bash
# Required: set project name, prd filename, test command
$EDITOR my-project/ralph/ralph.yaml

# Required: describe your stack and build commands for agents
$EDITOR my-project/ralph/AGENTS.md
```

### Step 5 — Write a PRD

```bash
# Option A: scaffold interactively via Claude Code skill
# Say: "create a prd" in Claude Code

# Option B: copy the template
cp ralph/templates/PRD_template.md PRD.md
$EDITOR PRD.md
```

### Step 6 — Run

```bash
cd my-project

# Optional: generate an implementation plan first
ralph/ralph.sh --mode plan
# Review IMPLEMENTATION_PLAN.md before proceeding

# Run the build loop
ralph/ralph.sh --iterations 3

# Check results
cat .ralph/tracking/progress.txt
```

## Install (manual alternative)

```bash
cp -r ralph/ /path/to/new-project/ralph/
# Edit ralph/ralph.yaml and ralph/AGENTS.md
```

## Project Setup

### PRD format

Ralph reads your PRD to select and track tasks. Create `PRD.md` at the project root
(filename is configured via the `prd:` key in `ralph/ralph.yaml`).

Each task must be a level-3 heading with a checkbox and a task ID:

```markdown
### [ ] US-001: Short Task Title

**Description**
What needs to be built.

**Acceptance Criteria**
- Concrete, verifiable condition
- Tests pass
```

Task IDs can use any prefix (`US-XXX`, `FEAT-XXX`, `TASK-XXX`). Ralph uses them as
the primary key for progress tracking — they must be unique within the file.

### Tracking copy vs source PRD

When Ralph runs, it copies your `PRD.md` into `.ralph/tracking/PRD.md` (the runtime copy).
Ralph reads and writes checkboxes there. **Always edit your source `PRD.md`**, not the
tracking copy. The tracking copy is re-synced at the start of each run.

### plan mode output

Running `ralph/ralph.sh --mode plan` reads your source PRD and writes
`IMPLEMENTATION_PLAN.md` at the **project root**. It performs a gap analysis
(what is already implemented vs what is missing) but never writes any code.
Review the plan before starting a build run.

## Common Commands

```bash
# Sequential loop (build mode, reads from ralph.yaml)
ralph/ralph.sh

# Planning mode: generate IMPLEMENTATION_PLAN.md from PRD
ralph/ralph.sh --mode plan

# Parallel agents (reads agent table from ralph.yaml parallel.agents)
ralph/ralph-parallel.sh

# Background self-improvement agent
ralph/ralph-think.sh

# Fire-and-forget, then check
ralph/ralph-think.sh
tail -f .ralph/logs/think/<latest>.log
```

## Core Options (`ralph.sh`)

| Option | Default | Description |
|--------|---------|-------------|
| `--mode build\|plan` | build | Build: implement tasks. Plan: generate IMPLEMENTATION_PLAN.md |
| `--iterations N` | 3 | Max Claude invocations |
| `--batch-size N` | 5 | Tasks to plan per run |
| `--task-id US-XXX` | — | Force a starting task (use your project's ID prefix) |
| `--timeout-sec N` | 900 | Per-iteration timeout |
| `--verbose` | off | Tail Claude log while running |
| `--dry-run` | off | Print actions without running Claude |
| `--tracking-dir PATH` | .ralph/tracking | Override tracking directory |
| `--branch NAME` | auto | Explicit branch name |
| `--no-tests` | off | Skip test execution |
| `--integrate` | off | Rebase + merge when done |
| `--cleanup` | off | Remove worktree on success |

## Project Config (`ralph/ralph.yaml`)

```yaml
project: myproject
prd: PRD_PROJECT.md      # source-of-truth requirements
merge_into: dev          # default merge target

runner:
  test: "docker build --target test ... && docker run ..."
  build: "docker build --target builder ..."
  dev: "docker compose up"

known_test_failures:
  - "SomeTest"           # pre-existing failures to ignore

parallel:
  agents:
    - label: A
      task: W02-001
      batch: 1
    - label: B
      task: W02-002
      batch: 2
```

## Operational Guide (`ralph/AGENTS.md`)

Agents read `AGENTS.md` every iteration for:
- Exact commands to run for build/test/dev
- Known pre-existing test failures to ignore
- Commit format rules
- Project-specific learnings (agents may append)

Keep it ~60 lines. Not a changelog.

## File Roles

| File | Role |
|------|------|
| `ralph.yaml` | Machine config: commands, parallel plan |
| `AGENTS.md` | Agent operational guide: commands, learnings |
| `PROMPT_build.md` | Agent instructions (build mode) |
| `PROMPT_plan.md` | Agent instructions (planning mode) |
| `IMPLEMENTATION_PLAN.md` | Generated by `--mode plan` at the project root |
| `references/playbook-summary.md` | Bundled best-practice reference |
| `skills/merge-worktree/SKILL.md` | Merge-worktree Claude skill |
| `skills/create-prd/SKILL.md` | Claude skill: scaffold a new PRD.md interactively |
| `skills/install/SKILL.md` | Claude skill: install ralph into another project |
| `skills/install/install.sh` | Install script (called by the install skill) |
| `templates/PRD_template.md` | Copy-and-fill PRD format template |

## Tracking Files (`.ralph/tracking/`)

| File | Purpose |
|------|---------|
| `PRD.md` | Task checklist — checkbox = done |
| `state.json` | Machine state (run_id, current_task, status) |
| `progress.txt` | Append-only execution log |
| `questions.md` | Agent clarification requests |
| `answers.md` | User answers |

**PRD checkbox is truth**: mark `[x]` only when acceptance criteria are met.

## Clarification Protocol

1. Agent sets `state.json.status = "NEEDS_CLARIFICATION"`
2. Agent writes questions to `questions.md`
3. User answers in `answers.md`
4. Re-run `ralph.sh` to resume

## Directory Layout (runtime, gitignored)

```
.ralph/
├── tracking/          # sequential run tracking
├── runs/
│   └── YYYYMMDD-HHMMSS/
│       └── agents/    # parallel agent tracking
│           ├── A/
│           └── B/
├── worktrees/         # git worktrees
├── logs/
│   └── YYYYMMDD-HHMMSS/
└── worktrees.json     # worktree ownership registry
```

## Dependencies

Required: `bash`, `git`, `python3`, `mktemp`, `date`, `rsync`, `claude` (or `npx`)

Optional: `curl` (for ntfy/slack/discord notifications)

## Git Safety

- Never force-push
- Never modify git config
- Use `git worktree remove --force` (not `rm -rf`) for worktree cleanup
- `git worktree prune` to clear stale entries
