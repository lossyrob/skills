# WorkflowContext

Work Title: Loop Supervised Watch
Work ID: loop-supervised-watch
Workflow Identity: paw-lite
Base Branch: main
Target Branch: feature/loop-supervised-watch
Execution Mode: worktree
Repository Identity: github.com/lossyrob/skills@b4bcd1fecabff4467e896db84e40691711b02be0
Execution Binding: worktree:loop-supervised-watch:feature/loop-supervised-watch
Workflow Mode: custom
Review Strategy: local
Review Policy: final-pr-only
Session Policy: continuous
Final Agent Review: enabled
Final Review Mode: single-model
Final Review Interactive: smart
Final Review Models: claude-opus-4.7-high
Final Review Specialists: all
Final Review Interaction Mode: parallel
Final Review Specialist Models: none
Final Review Perspectives: auto
Final Review Perspective Cap: 2
Implementation Model: none
Plan Generation Mode: single-model
Plan Generation Models: gpt-5.5
Planning Docs Review: enabled
Planning Review Mode: single-model
Planning Review Interactive: smart
Planning Review Models: claude-opus-4.7-high
Planning Review Specialists: all
Planning Review Interaction Mode: parallel
Planning Review Specialist Models: none
Planning Review Perspectives: auto
Planning Review Perspective Cap: 2
Custom Workflow Instructions: Human review and approval is required after planning only. Continue design conversation after PAW init before finalizing the plan. The work targets a hardened observed watch design for long loop waits using the existing detached worker plus attached/backgrounded waiter model, including explicit watch-until-terminal timeout intent, cleanup and retention, missing-helper recovery, structured wakeup metadata, documentation, and tests. A separate supervisor process, watch root, and generation tree are deferred unless v1 evidence proves they are necessary.
Initial Prompt: Run the hardened observed watch design through PAW Lite using a worktree and commit-and-clean artifact lifecycle. Planning docs review and final review are single-model reviews using claude-opus-4.7-high.
Issue URL: none
Remote: origin
Artifact Lifecycle: commit-and-clean
Artifact Paths: auto-derived
Additional Inputs: planning-only human review is represented as a custom workflow instruction because paw-lite requires Review Policy: final-pr-only.

## Control State

TODO Mirror: active-required-items
Reconciliation: current

### Required Workflow Items
- `init` | `resolved` | `activity`
- `planning` | `resolved` | `activity`
- `planning-docs-review` | `pending` | `activity`
- `implementation` | `pending` | `activity`
- `final-review` | `pending` | `activity`
- `final-pr` | `pending` | `activity`

### Configured Procedure Items
- `procedure:planning-review` | `pending` | `procedure`
- `procedure:final-review` | `pending` | `procedure`
