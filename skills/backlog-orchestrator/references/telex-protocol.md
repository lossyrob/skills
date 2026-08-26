# Telex protocol (CLI run-specific contract)

This file defines the Copilot CLI coordination contract for a backlog run: addresses, scope, tags, and
the message vocabulary exchanged by terminal workers.

**Telex mechanics are owned by the telex skill.** Every CLI session loads the version-matched
instructions:

```sh
telex skill
telex copilot skill
```

Copilot CLI uses telex push delivery: bind the in-session bridge once and messages arrive as turns.
Do not run or re-arm `telex wait`. Follow `telex copilot skill` for exact bind, receive, acknowledge,
send, recover, and detach syntax.

## Backend and run identity

All sessions in one run share exactly one telex store. Select it at setup, persist it as
`run_meta.telex_backend`, and inject it into every CLI worker prompt.

- **Run id:** a short slug such as `rb-2026-08-25a`.
- **Scope:** `backlog:<runid>`.
- **Tags:** `run:<runid>`, `repo:<owner/repo>`, `role:orchestrator|implementer|reviewer`, and
  `issue:<n>` for workers.

## Addresses

| Session | Address |
|---|---|
| Orchestrator | `orchestrator:<runid>` |
| Implementer | `impl:<runid>:issue-<n>` |
| Reviewer | `review:<runid>:issue-<n>` |

Each session binds its own address so messages are repliable. The orchestrator's push bridge receives
worker messages as turns.

Before triage launches any worker, the orchestrator must bind `orchestrator:<runid>` on the selected
backend with scope `backlog:<runid>`, tags `run:<runid>,repo:<owner/repo>,role:orchestrator`, and an
appropriate description, then provision the Copilot push bridge per `telex copilot skill`. Persist
that address as `run_meta.orchestrator_address`.

## Message vocabulary

| kind | direction | attention | meaning |
|---|---|---|---|
| `review-ready` | impl -> review | `next-checkpoint` | PR is open, CI green, and ready for first review. Metadata: `{pr, headSha, repo, issue}`. |
| `review-posted` | review -> impl | `next-checkpoint` | Submitted GitHub review has blocking feedback. |
| `review-approved` | review -> impl | `next-checkpoint` | Submitted review starts with `🐾 PAW Review: +1`; no blocking feedback remains. |
| `rereview-requested` | impl -> review | `next-checkpoint` | Feedback or substantive repairs were pushed and CI is green again. |
| `merge-ready` | impl -> orchestrator | `interrupt` | Review is approved when required, CI is green, merge state is clean, and field report already exists. |
| `blocked` | impl -> orchestrator | `interrupt` | Hard blocker needs orchestrator or human action. |
| `process-feedback` | impl/review -> orchestrator | `background` | Workflow feedback; not disposition-required. |
| `human-review-pending` | orchestrator -> impl/review | `interrupt` | Route is human review; implementer keeps the sentry alive and reviewer remains available. |
| `merged` | impl -> orchestrator | `interrupt` | Builder merged a human-pended PR; implementer requests stand-down. |
| `stand-down-merged` | orchestrator -> impl/review | `interrupt` | PR merged; stop sentry, report feedback, clean up, and end. |
| `stand-down-human` | orchestrator -> impl/review | `interrupt` | Terminal stop without merge; stop sentry, report feedback, clean up, and end. |

Put structured fields in message metadata and a concise human-readable summary in the body. Mark
actionable messages disposition-required. Act on a received turn, then disposition it by id.

Human-review handoff is deferred: send `human-review-pending`, advance to the next issue, and leave the
terminal workers alive. The implementer later sends `merged`; only then send `stand-down-merged`.
Messages from past held issues may interleave with the current issue, so identify them by sender and
metadata.

The GitHub review and field report remain the auditable source of truth. Telex carries wakeups and
pointers; workers do not poll GitHub comments for handoffs.

## Cleanup

At full run completion, detach bridges and retire all run addresses using the verbs documented by
`telex copilot skill` and `telex address --help`.
