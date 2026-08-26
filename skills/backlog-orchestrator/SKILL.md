---
name: backlog-orchestrator
description: Drive a backlog of GitHub issues to PRs autonomously and sequentially in either the GitHub Copilot app or Copilot CLI. The orchestrator detects the runtime, then uses app-native child sessions and messaging or terminal workers and telex while sharing triage, merge-gate, deferred-work, and reporting policy. Use when asked to work through a backlog/queue of issues autonomously, run an autonomous issue-fixing pipeline, or orchestrate PAW sessions across many issues.
compatibility: "Requires GitHub CLI authenticated for the target repo, paw-pr-lifecycle, spar, the PAW workflow skills, and the PAW-Review custom agent. App mode additionally requires project child-session, messaging, automation, and archival tools. CLI mode additionally requires Copilot CLI, telex, launch-copilot-terminal, and loop."
---

# Backlog Orchestrator

Use this skill when the user wants to autonomously work through a backlog of GitHub issues: each
issue is taken to a pull request by an autonomous PAW **implementer** session, optionally reviewed by
an autonomous PAW **reviewer** session, and then either **auto-merged** or **routed to human review**
by you, the orchestrator. The whole run is **sequential** — one issue end-to-end at a time — until
every selected issue's PR is in a terminal state (merged, pending human review, or blocked).

You are the **orchestrator**. You do not write feature code. You select the runtime, triage, create
workers, coordinate them through that runtime's transport, gate merges, clean up workers, and report.

## The model in one paragraph

First select `app` or `cli` using [references/runtime-selection.md](references/runtime-selection.md).
In app mode, workers are app-managed child project sessions coordinated with native messages, and the
implementer uses session automation for its merge sentry. In CLI mode, workers run in separate
terminal/worktree sessions coordinated through telex, and the implementer uses the loop-based sentry.
In both modes the implementer runs the configured PAW workflow, the optional `PAW-Review` worker
submits real GitHub reviews, and the review handshake remains "review ready" → "review posted" →
"re-review requested" → "+1". When merge-ready, the implementer posts a field report and signals you.
You run a last-line **preference / human-floor review** (a subagent, not a correctness review) that reads
that field report, then either squash-merge (and `stand-down-merged`) or route to **human review**. On a
human-review route you do **not** stand the worker down: you send `human-review-pending` so the
implementer's sentry keeps the PR mergeable until the **builder** merges; the implementer then messages
you `merged`, and only then do you stand it down. Either way, you advance to the next issue.

## The four phases

| Phase | What you do | Reference |
|---|---|---|
| 1. Runtime + run setup | Detect and persist `app` or `cli`, then load that mode's protocol. | [references/runtime-selection.md](references/runtime-selection.md) |
| 2. Triage | With the user: select issues, size S/M/L, set per-tier + per-issue config (impl PAW config, reviewer on/off + PAW Review config, **merge disposition**, **care knob**, **posture**). | [references/triage.md](references/triage.md) |
| 3. Per-issue execution | Dispatch to the selected runtime lifecycle and drive one implementer (+ optional reviewer) pair. | [references/lifecycle.md](references/lifecycle.md) |
| 4. Merge gate + advance | Run the last-line review, decide merge vs human, merge, stand down workers, advance. | [references/merge-gate.md](references/merge-gate.md) |
| (cross-cutting) Reporting | Maintain the run ledger; produce the status/final report on demand. | [references/reporting.md](references/reporting.md) |

Worker prompts are runtime-specific. The runtime selector names the exact app or CLI templates.

## Prerequisites (verify before starting)

- Select and validate a runtime using [references/runtime-selection.md](references/runtime-selection.md).
  - App mode requires `create_session`, `send_session_message`, `save_session_automation`,
    `get_session`, `respond_to_session_plan`, and `archive_session`, plus project/session context.
  - CLI mode requires `copilot`, `telex`, `loop`, and the
    `launch-copilot-terminal` skill with the host-specific launcher.
- `gh` authenticated for the target repo. **Follow the user's Copilot instructions for which gh
  account/config to use** (personal vs work). The orchestrator and the workers must all use an account
  that can read the repo, push, open PRs, and (for the orchestrator) merge.
- The PAW workflow skills, `paw-pr-lifecycle`, and `spar` installed; the reviewer requires the
  `PAW-Review` custom agent.
  App workers use their native session automation for sentry wakeups. CLI workers additionally rely on
  `loop`.

## Operating principles

- **Sequential.** Exactly one implementer (+ optional reviewer) pair is *being driven* at a time. Do not
  pipeline issues in v1. "Pending human review" is terminal **for advancement** — you move on to the next
  issue and do not block on the human — but that issue's implementer stays alive in sentry mode (holding
  the PR mergeable) until the builder merges and you stand it down. So idle held workers from earlier
  issues may coexist with the one you are actively driving; that is expected, not pipelining.
- **Human-review holds outlive backlog advancement.** A backlog report may be produced while routed PRs
  remain open, but the orchestrator remains available through its selected transport until workers
  stand down.
- **Transport = coordination; GitHub = source of truth.** App messages or telex carry wakeups,
  pointers, and state transitions; reviews, PRs, and merges live on GitHub.
- **You never run the merge sentry.** That is the implementer's loop. You react to the implementer's
  "ready for merge" message.
- **Autonomy with surfacing.** Run hands-off. Surface to the user only: blockers, and the
  status/final report when asked. Everything you decide (especially **preference debt** and
  **no-auto-merge** calls) is recorded in the ledger so the report can bubble it up.
- **Deferred work is tracked to a terminal disposition — symmetric to preference debt.** Preference forks
  get harvest → well-lit bet → route/record; deferred/carry-forward work gets the *same* forcing function:
  the merge gate **harvests** it (field report + diff markers) at `merge-ready`, you record each item in
  the `deferred` table, and **no item stays `open`** — each reaches filed / folded / skipped(+reason) /
  done / moot, triaged with the builder. The run is not complete while any deferred item is `open`
  ([merge-gate.md](references/merge-gate.md), [reporting.md](references/reporting.md)).
- **The orchestrator owns durable shared state.** Workers own only their worktree/PR/issue comments.
- **Continuous improvement.** Workers report `process-feedback` at finish; record the runtime and
  improve the corresponding templates/protocol rather than applying transport-specific feedback to
  both modes.
- **Fix what's broken (encoded builder value).** If something is broken — failing CI, a build break, an
  obvious bug — fix it, even if it expands the PR's scope, *especially when low-risk*. It is a settled
  norm, not a preference fork to route; record the drive-by fix in the PR body and field report.

## Quickstart runbook

1. Confirm prerequisites; pick a short **run id** (e.g. `rb-2026-06-17a`).
2. Persist `runtime_mode` and initialize its protocol state.
3. Triage with the user → persist the run manifest (triage.md).
4. For each issue in order → execute (lifecycle.md) → merge gate (merge-gate.md) → record + advance.
5. When all issues are terminal, resolve deferred work, perform mode-specific cleanup, and produce the
   final report (reporting.md).
