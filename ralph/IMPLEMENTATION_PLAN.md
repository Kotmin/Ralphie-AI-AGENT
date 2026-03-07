# Ralph Self-Improvement Plan

Maintained by `ralph-think.sh`. Documents what ralph currently has, gaps vs best practices,
and improvement tasks. Regenerate when stale.

## Current Capabilities (inventory)

- Sequential loop: `ralph.sh` with test-and-fix, no-op detection, clarification protocol
- Parallel orchestration: `ralph-parallel.sh` (generic via ralph.yaml)
- State management: JSON state + PRD checkbox tracking
- Worktree isolation: git worktrees per run, registry in worktrees.json
- Notifications: `notify.sh` (mock, ntfy, slack, discord backends)
- Planning mode: `PROMPT_plan.md` + `--mode plan` flag
- Building mode: `PROMPT_build.md` (default)
- Agent guide: `AGENTS.md` with operational context
- Project config: `ralph.yaml` (test/build/dev commands, parallel agent table)
- Skills: `merge-worktree` (validate → test → rebase → ff-merge → mark-done → cleanup)
- Playbook reference: `references/playbook-summary.md`
- Background think agent: `ralph-think.sh`

## Gaps vs Huntley Playbook

### [ ] US-P01: Specs directory pattern
- Huntley uses `specs/*.md` (one file per topic) as source-of-truth requirements
- We use `PRD.md` (monolithic) — works but harder to scope per-task
- Consider: add `specs/` generation from PRD sections as optional enhancement

### [ ] US-P02: LLM-as-Judge test fixtures
- Huntley recommends binary pass/fail LLM validators for subjective criteria
- We have no mechanism for non-code validation (UX, output tone, doc quality)

### [ ] US-P03: Work-scoped IMPLEMENTATION_PLAN
- Huntley: `./loop.sh plan-work "scope description"` creates scoped plan per branch
- We: planning mode writes a full plan covering all unchecked PRD tasks
- Enhancement: add `ralph.sh --mode plan --scope "description"` to limit scope

### [ ] US-P04: PROMPT_build.md guardrail numbering
- Huntley uses 999+, 9999+ numbering for critical guardrails
- Our PROMPT_build.md uses free-form sections
- Enhancement: reorganize prompts with numbered guardrail system

### [ ] US-P05: Context efficiency — main agent as coordinator
- Huntley: main agent spawns subagents for reads, uses 1 subagent for tests
- We: agent does all work inline (no explicit subagent strategy in prompt)
- Enhancement: update PROMPT_build.md to instruct parallel subagents for exploration

### [ ] US-P06: Plan regeneration workflow
- No documented trigger/command for "regenerate stale plan"
- Enhancement: add `ralph.sh --mode plan --force-regen` that overwrites IMPLEMENTATION_PLAN.md

## Completed Improvements

### [x] US-R01: Directory restructure
- Moved from `scripts/ralph/` to `ralph/` (portable, self-contained)
- Added `ralph.yaml` for project config (single source of truth for commands)
- Added `AGENTS.md` for agent operational guide
- Fixed tracking dir naming consistency (parallel: `.ralph/runs/<run_id>/agents/<label>/`)
- Fixed null log dir bug in ralph.sh
- Added planning mode (`PROMPT_plan.md`, `--mode plan` flag)
- Added `ralph-think.sh` background self-improvement agent
- Added `merge-worktree` skill
- Generic PRD parsing: supports US-XXX and W##-### task ID formats
