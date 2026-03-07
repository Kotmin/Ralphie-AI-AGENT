# PRD.md — Ralphie Autonomous Loop Stabilization

## Purpose

Ralphie is a minimal, production-oriented autonomous task loop for Claude Code.
It operates using **fresh Claude sessions**, **git worktrees**, and **persistent local state**.

This PRD defines what must be **implemented or fixed** so Ralphie can run safely,
repeatably, and autonomously without corrupting the repository or hallucinating state.

Scope constraint:
- ❌ No new application
- ❌ No architecture rewrite
- ✅ Fix and complete the existing loop

---

## Core Principles

- Git safety over speed
- Determinism over cleverness
- Stop instead of guessing
- PRD.md is the single source of truth
- Each Claude invocation is stateless

---

## Task List

### [ ] US-001: Repository State Scan (Bootstrap)

**Description**  
At startup, Ralph must scan the current repository to understand its structure
and validate that required files exist.

This scan is used to ground Claude in real filesystem state.

**Acceptance Criteria**
- Detects presence of `CLAUDE.md`
- Detects `.ralph/` directory and substructure
- Produces a deterministic repo summary
- Fails fast if required files are missing
- No assumptions about repo contents

---

### [ ] US-002: Command Capability Verification

**Description**  
Before running autonomously, Ralph must verify all required system commands
are available and executable.

**Required Commands**
- `bash`
- `git`
- `git worktree`
- `python3`
- `mktemp`
- `rsync`
- `date`
- `claude` OR `npx @anthropic-ai/claude-code`

**Acceptance Criteria**
- Missing commands stop execution immediately
- Error output lists exact missing commands
- No partial execution occurs

---

### [ ] US-003: Deterministic Task Selection

**Description**  
Ralph must deterministically select the next task from this PRD.

**Rules**
1. If `--task-id` is provided, use it
2. Otherwise, select the first unchecked task
3. If no unchecked tasks remain, set status to `DONE`

**Acceptance Criteria**
- No task skipping
- Same PRD produces same task order
- Selected task is written to `state.json`

---

### [ ] US-004: Git Worktree Lifecycle Management

**Description**  
Each run must operate inside an isolated git worktree.

**Rules**
- Worktrees are created under `.ralph/worktrees/<run_id>`
- No changes occur in the main working tree
- Worktree cleanup is explicit and optional

**Acceptance Criteria**
- Root repo remains clean
- Worktree can be deleted safely
- Worktree path is recorded in logs/state

---

### [ ] US-005: Fresh Claude Session Per Iteration

**Description**  
Each iteration must invoke Claude Code in a new headless process
with no conversation history.

**Rules**
- No chat reuse
- No implicit memory
- Only prompt + tracking files are provided

**Acceptance Criteria**
- Each iteration is a new process
- Context does not grow unbounded
- No reference to previous iterations unless persisted

---

### [ ] US-006: Iterative Test-and-Fix Loop

**Description**  
For tasks involving code changes, Ralph must validate its work
and retry when failures occur.

**Rules**
- Run tests or validation after changes
- Max retries per task: configurable (default 3)
- Each retry includes failure analysis

**Acceptance Criteria**
- Failed tests trigger retries
- Infinite loops are impossible
- Final failure is explicit and logged

---

### [ ] US-007: Safe Stop & Fallback Handling

**Description**  
Ralph must stop safely when progress is no longer possible.

**Stop Conditions**
- Iteration limit reached
- Repeated test failures
- Missing system commands
- Claude exits non-zero
- Rate limits
- Ambiguous requirements

**Acceptance Criteria**
- `state.json.status` reflects stop reason
- No partial commits
- Clear logs explaining why execution stopped

---

### [ ] US-008: Clarification Protocol Enforcement

**Description**  
When requirements are ambiguous, Ralph must request clarification
instead of guessing.

**Rules**
- Write questions to `questions.md`
- Set state to `NEEDS_CLARIFICATION`
- Resume only after answers exist

**Acceptance Criteria**
- No speculative changes
- Execution pauses cleanly
- User answers unblock execution

---

### [ ] US-009: Commit Discipline Enforcement

**Description**  
Each completed task must produce exactly one clean commit.

**Rules**
- Commit only after acceptance criteria pass
- Commit message format: `US-XXX: <task title>`
- No mixed-task commits

**Acceptance Criteria**
- Clean git status after commit
- Commit maps to exactly one task
- Task checkbox updated only after commit

---

### [ ] US-010: Observability & Logging

**Description**  
Ralph must be debuggable after failure.

**Requirements**
- Append-only `progress.txt`
- Per-iteration logs
- Deterministic `run_id`

**Acceptance Criteria**
- Human can reconstruct what happened
- Logs align with state transitions

---

### [ ] US-011: Test Command Discovery & Execution

**Description**  
Ralph must determine how to validate code changes based on repository context.

Test execution is optional but must be explicit when available.

**Discovery Rules (in order)**
1. If test command is defined in PRD task → use it
2. If repo config defines a test command → use it
3. If common framework test command detected → suggest it
4. If no test mechanism exists → log and skip

**Examples**
- Python: `pytest`, `python -m unittest`
- Node: `npm test`, `pnpm test`
- Rails: `bundle exec rspec`, `rails test`

**Acceptance Criteria**
- Test commands are never guessed blindly
- Failed tests trigger retry logic
- Absence of tests does not cause failure

---

### [ ] US-012: Integrate Changes with Rebase-and-Prove Strategy

**Description**  
Ralph integrates completed worktree commits back into the invoked branch using
a rebase-first strategy, but only finalizes integration if validation passes.

**Rules**
- Target is the invoked branch detected at start
- Integration strategy:
  1) Attempt `git rebase <invoked_branch>` within the worktree
  2) If conflicts:
     - attempt resolution only for mechanically safe cases (whitespace-only,
       non-overlapping changes, or auto-merge that produces zero conflict markers)
     - re-run tests/validation after resolution
     - if tests fail or conflict markers remain → stop and request clarification
  3) If rebase succeeds and tests pass:
     - fast-forward invoked branch to the rebased worktree commit (or merge cleanly)

**Acceptance Criteria**
- Conflicts are never “papered over”: either resolved + proven by tests, or stopped
- No unresolved conflict markers can exist in final integration
- Invoked branch ends in a state where configured validation passes
- No force push


---

### [ ] US-013: Optional Safe Sync of Invoked Branch

**Description**  
Before integrating worktree commits, Ralph may sync the invoked branch safely.

**Rules**
- `git fetch` always allowed
- If remote tracking branch exists:
  - allow `git pull --ff-only`
  - if ff-only fails → stop and ask (do not auto-merge remote changes)

**Acceptance Criteria**
- Sync never creates merge commits automatically
- If ff-only isn’t possible, Ralph stops with a clear message


---

### [ ] US-014: Ralph-Managed Worktree Cleanup & Orphan Recovery

**Description**  
Ralph must clean up git worktrees it created when they are no longer needed,
and avoid leaving orphaned or unusable worktrees after failures.

Cleanup must be safe: Ralph may only remove worktrees that it explicitly owns.

**Ownership Rule**
- Every worktree created by Ralph is recorded in tracking metadata, including:
  - run_id
  - absolute path
  - created timestamp
  - base branch (invoked branch)
  - owning tool identifier (e.g., `owner=ralph`)
- Cleanup operates only on worktrees that match recorded ownership metadata

**Cleanup Modes**
- Default: keep worktree on failure for debugging
- `--cleanup`: remove worktree after successful completion
- `--cleanup-on-fail`: remove worktree even on failure (best effort)
- `--cleanup-stale`: remove worktrees created by Ralph that are older than N days and not active

**Failure/Orphan Handling**
- If Ralph crashes mid-run, next run should detect orphaned Ralph worktrees
  and either:
  - resume (if state indicates active run), or
  - offer safe cleanup (if stale)

**Acceptance Criteria**
- Successful run with `--cleanup` leaves no Ralph worktree behind
- Failed run does not leave an unusable/locked worktree (git prune performed)
- Orphaned Ralph worktrees are detectable and recoverable
- All removals are logged with paths and run_id


---


## State Machine

Valid `state.json.status` values:
- `IDLE`
- `IN_PROGRESS`
- `DONE`
- `STOPPED`
- `ERROR`
- `RATE_LIMIT`
- `NEEDS_CLARIFICATION`

Rules:
- Status changes are explicit
- STOPPED is not an error
- ERROR requires human intervention

---

## Definition of Done

Ralph is considered production-ready when:
- It can run unattended
- It never corrupts the repository
- It stops instead of guessing
- A human can resume from any state

---

## Open Questions (Intentional)

- What is the default test command when none is defined?
- Should retries reset the worktree or reuse it?
- Should failed tasks block the entire run?

These must be resolved via the clarification protocol.
