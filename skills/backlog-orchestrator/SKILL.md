---
name: backlog-orchestrator
description: Drive a backlog of GitHub issues to PRs autonomously and sequentially. The loaded session becomes an orchestrator that triages issues into S/M/L tiers, spawns PAW implementer (and optional PAW Review) worker terminals that coordinate over telex instead of GitHub-comment polling, gates each PR through a preference/human-floor merge review, and auto-merges or routes to human review. Use when asked to work through a backlog/queue of issues autonomously, run an autonomous issue-fixing pipeline, or orchestrate PAW sessions across many issues.
compatibility: "Requires Windows + Windows Terminal (for launch-copilot-terminal), Copilot CLI on PATH, telex on PATH, GitHub CLI authenticated for the target repo, and the installed skills: launch-copilot-terminal, paw-pr-lifecycle, loop, and the PAW workflow skills (paw-lite / paw-review-workflow)."
---

# Backlog Orchestrator

Use this skill when the user wants to autonomously work through a backlog of GitHub issues: each
issue is taken to a pull request by an autonomous PAW **implementer** session, optionally reviewed by
an autonomous PAW **reviewer** session, and then either **auto-merged** or **routed to human review**
by you, the orchestrator. The whole run is **sequential** — one issue end-to-end at a time — until
every selected issue's PR is in a terminal state (merged, pending human review, or blocked).

You are the **orchestrator**. You do not write feature code. You triage, spawn workers, coordinate
them over telex, gate merges, merge, and report.

## The model in one paragraph

Worker sessions run in their own Windows Terminal tabs (via `launch-copilot-terminal`) and in their
own git worktrees. The **implementer** runs the PAW workflow (config `Workflow Identity`, e.g. `paw-lite`,
loaded as a skill — *not* launched as the `PAW` agent) → opens a PR. If the tier calls for it, a
**reviewer** — launched **as the `PAW-Review` custom agent** (`--agent PAW-Review`), with its prompt
authorizing autonomous review submission — runs the PAW Review workflow → submits a real GitHub PR review.
The implementer and reviewer hand off the review cycle **over telex** (not GitHub-comment polling loops):
"review ready" → "review posted" → "re-review requested" → "+1". The implementer keeps using the
**`loop`-based merge sentry** to repair CI failures and merge conflicts (this stays a loop — telex does
not replace it). When the PR is merge-ready, the implementer **posts its field report on the issue** and messages **you**.
You run a last-line **preference / human-floor review** (a subagent, not a correctness review) that reads
that field report, then either squash-merge (and `stand-down-merged`) or route to **human review**. On a
human-review route you do **not** stand the worker down: you send `human-review-pending` so the
implementer's sentry keeps the PR mergeable until the **builder** merges; the implementer then messages
you `merged`, and only then do you stand it down. Either way, you advance to the next issue.

## The four phases

| Phase | What you do | Reference |
|---|---|---|
| 1. Station setup | Stand up your telex station (holder + re-armed `wait`). | [references/telex-protocol.md](references/telex-protocol.md) |
| 2. Triage | With the user: select issues, size S/M/L, set per-tier + per-issue config (impl PAW config, reviewer on/off + PAW Review config, **merge disposition**, **care knob**, **posture**). | [references/triage.md](references/triage.md) |
| 3. Per-issue execution | Sequentially launch implementer (+ optional reviewer), coordinate over telex until "ready for merge" or "blocked". | [references/lifecycle.md](references/lifecycle.md) |
| 4. Merge gate + advance | Run the last-line review, decide merge vs human, merge, stand down workers, advance. | [references/merge-gate.md](references/merge-gate.md) |
| (cross-cutting) Reporting | Maintain the run ledger; produce the status/final report on demand. | [references/reporting.md](references/reporting.md) |

Worker launch prompts are generated from bundled, parameterized templates:
[templates/implementer-prompt.md](templates/implementer-prompt.md) and
[templates/reviewer-prompt.md](templates/reviewer-prompt.md).

## Prerequisites (verify before starting)

- `telex` on PATH (`telex skill` for the messaging model). **Pick one telex `<backend>` for the whole
  run and pin it** with `--backend <backend>` on every telex command (orchestrator + workers); capture
  it in the run manifest. `local` sqlite (`~/.telex/local.db`) is a fine default, but **never rely on
  the telex default backend** — if the user changes the default mid-run (e.g. to a Postgres backend),
  unqualified commands route to the wrong store, holders look unoccupied, and waiters never wake. This
  is a real failure mode; see [references/telex-protocol.md](references/telex-protocol.md).
- `launch-copilot-terminal` skill installed (resolve its actual installed path; do not assume
  `~/.copilot/skills`). Workers are Copilot CLI tabs launched with `--allow-all` for autonomy. The
  reviewer is additionally launched with `--agent PAW-Review`, so the **`PAW-Review` custom agent must be
  installed** (`~/.copilot/agents/PAW-Review.agent.md`); confirm `copilot --help` lists `--agent` and the
  agent resolves. (The implementer is a general session that loads its PAW skill via the prompt — no
  `--agent`.)
- `gh` authenticated for the target repo. **Follow the user's Copilot instructions for which gh
  account/config to use** (personal vs work). The orchestrator and the workers must all use an account
  that can read the repo, push, open PRs, and (for the orchestrator) merge.
- The PAW skills and `paw-pr-lifecycle` + `loop` skills installed (workers rely on them).

## Operating principles

- **Sequential.** Exactly one implementer (+ optional reviewer) pair is *being driven* at a time. Do not
  pipeline issues in v1. "Pending human review" is terminal **for advancement** — you move on to the next
  issue and do not block on the human — but that issue's implementer stays alive in sentry mode (holding
  the PR mergeable) until the builder merges and you stand it down. So idle held workers from earlier
  issues may coexist with the one you are actively driving; that is expected, not pipelining.
- **Telex = coordination; GitHub = source of truth.** Reviews, PRs, and merges live on GitHub; telex
  only carries wakeups + pointers between sessions.
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
- **Continuous improvement.** Workers report `process-feedback` at finish; absorb those learnings and
  proactively improve this skill as you go (templates, telex protocol, triage, config).
- **Fix what's broken (encoded builder value).** If something is broken — failing CI, a build break, an
  obvious bug — fix it, even if it expands the PR's scope, *especially when low-risk*. It is a settled
  norm, not a preference fork to route; record the drive-by fix in the PR body and field report.

## Quickstart runbook

1. Confirm prerequisites; pick a short **run id** (e.g. `rb-2026-06-17a`).
2. Stand up your station (telex-protocol.md).
3. Triage with the user → persist the run manifest (triage.md).
4. For each issue in order → execute (lifecycle.md) → merge gate (merge-gate.md) → record + advance.
5. When all issues are terminal, produce the final report (reporting.md).
