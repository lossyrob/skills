# App session protocol (run-specific contract)

This file defines the app-native coordination contract for a backlog run: how the orchestrator creates
child project sessions, how session ids are shared, and the message vocabulary exchanged through the
app. There is no terminal launcher, telex bridge, shared message store, or worker-side message poller.

## Session topology

- **Orchestrator:** the current app project session. Its `project_session_id` comes from workspace
  context and is persisted as `orchestrator_session_id`.
- **Implementer:** one local worktree child session per issue, created with `create_session`.
- **Reviewer:** an optional second local worktree child session, created with `create_session` and
  `kickoff.agent: "PAW-Review"`.

Create every child with `coordinate_with_creator: true`, `execution_location: "local"`,
`workspace_type: "worktree"`, and an autopilot kickoff. Omit
`base_branch` when the project default is correct. Pass it only when the issue explicitly targets
another existing branch. Omit `project_id` when the backlog belongs to the current project; otherwise
use the exact configured project id selected during triage.

Persist the ids returned by `create_session` on the issue row:

| Role | Session name | Persisted column |
|---|---|---|
| Implementer | `<runid> impl #<n>` | `implementer_session_id` |
| Reviewer | `<runid> review #<n>` | `reviewer_session_id` |

The orchestrator id is known before launch. Create the reviewer first when enabled, then the
implementer. The implementer kickoff can therefore include the reviewer id. Immediately after the
implementer is created, send the reviewer a `peer-registered` message containing the implementer id.

## Native message transport

Send coordination events with `send_session_message` to the exact target session id:

- use `delivery_mode: "immediate"` for every lifecycle event so an active session sees new information
  promptly and an idle session wakes immediately;
- use `mode: "autopilot"` for worker-directed events; omit `mode` when a worker sends to the
  orchestrator so the parent retains its current operating mode;
- never use another session's display name as an address;
- do not poll GitHub comments or session status for handoff events.

Child-to-parent messages arrive in the orchestrator as app-native cross-session messages. The child
uses the orchestrator id from its kickoff prompt with `send_session_message`. Conversation history is
the durable delivery record, so there is no acknowledgement or disposition database.

Every coordination message starts with this compact envelope, followed by a human-readable summary:

```text
BACKLOG_EVENT
run_id: <runid>
kind: <kind>
issue: <n>
pr: <number-or-none>
head_sha: <sha-or-none>
field_report_url: <url-or-none>
reason: <reason-or-none>
event_id: <stable-idempotency-key>

<one or more concise details>
```

Receivers must reject events whose `run_id` or `issue` does not match their assignment. The
orchestrator must also verify the sender session id against the manifest before acting. For review
requests, use deterministic event ids (`review-ready:<head_sha>` and `rereview-requested:<head_sha>`)
and ignore a replay whose event id was already accepted.

## Message vocabulary

| kind | direction | meaning |
|---|---|---|
| `peer-registered` | orchestrator -> review | Supplies the issue's `implementer_session_id`; reviewer records it and waits for work. |
| `review-ready` | impl -> review | PR is open, CI green, and ready for first review. Includes `{pr, head_sha, repo, issue}`. |
| `review-received` | review -> impl | Reviewer accepted a review request and records its event id before beginning work. |
| `review-posted` | review -> impl | A submitted GitHub review has blocking feedback. |
| `review-approved` | review -> impl | A submitted review begins with `PAW Review: +1` marker and has no blocking feedback. |
| `rereview-requested` | impl -> review | Feedback was addressed or substantive repairs were pushed; CI is green again. |
| `merge-ready` | impl -> orchestrator | Review is approved when required, CI is green, merge state is clean, and the field report already exists. |
| `blocked` | impl -> orchestrator | A hard blocker needs an orchestrator or human decision. |
| `process-feedback` | impl/review -> orchestrator | Workflow feedback for improving the skill. |
| `human-review-pending` | orchestrator -> impl/review | Route is human review; implementer keeps its sentry automation active and reviewer remains available. |
| `merged` | impl -> orchestrator | A human-pended PR was merged by the builder; implementer requests stand-down. |
| `stand-down-merged` | orchestrator -> impl/review | PR merged; clear automation, add any field-report addendum, report feedback, and finish. |
| `stand-down-human` | orchestrator -> impl/review | Terminal stop without a merge; clear automation, report feedback, and finish. |
| `stand-down-complete` | impl/review -> orchestrator | Worker completed stand-down; record and retain its app session. |

The GitHub review and field report remain the auditable source of truth. Native messages carry
wakeups, session pointers, and state transitions.

## Idle workers and merge sentry

App child sessions naturally go idle between turns. They normally wake when another session sends a
native message. Review requests use a lightweight receipt/replay guard because an immediate send can
occasionally succeed without waking an idle child:

1. Implementer sends `review-ready` or `rereview-requested` with a deterministic event id.
2. Reviewer immediately replies `review-received` with that event id, then starts the review.
3. Implementer schedules one one-time recovery wake for five minutes later. On that wake, if no
   matching receipt arrived, inspect the reviewer once with `get_session` and replay the same event id
   exactly once. If the receipt arrived, clear the recovery automation.
4. Reviewer treats the replay as idempotent: acknowledge it but do not start a duplicate review for an
   event id already accepted.

This bounded recovery is app-specific. Do not add it to the CLI/telex path, whose store already
buffers and redelivers messages.

The implementer's merge sentry is different: it must detect CI failures, base movement, conflicts, and
a human merge without an incoming message. Once the PR first becomes merge-ready, the implementer
uses `save_session_automation` to attach a recurring 15-minute autopilot check to its own session. Each
wake checks the PR, repairs actionable failures, requests re-review after substantive changes, and
otherwise ends the turn. Stand-down clears the automation with `save_session_automation({clear:true})`.

## Recovery and retained sessions

- Normal coordination is event-driven. Do not repeatedly call `get_session` while waiting.
- For an unacknowledged app review request, use the single receipt/replay recovery above before
  treating the reviewer as silent.
- If a worker is unexpectedly silent, inspect it once with `get_session`. If it is awaiting plan
  approval, review the plan and use `respond_to_session_plan`; normal workers should be launched in
  autopilot specifically to avoid this state.
- If a worker failed, send a corrective native message or relaunch only after checking whether its PR
  or sibling session already progressed.
- After receiving `stand-down-complete`, retain the child session and its app-managed worktree so the
  builder can inspect or resume it. Record its final status and session id in the report.
- Archive only when the user explicitly asks to remove completed sessions. Use `archive_session`; never
  delete app-managed worktrees manually. On Windows, archival can fail while the retained child
  `copilot.exe` or parent app still holds the worktree directory. Report that error and leave the
  session intact rather than retrying or forcing process termination.
- Human-review sessions remain unarchived until the builder merges or abandons the PR and the workers
  complete stand-down.
- The orchestrator session must remain resident while any human-review hold exists. The backlog pass
  may report completion and stop driving new issues, but the run remains live until every held PR is
  merged or abandoned and its workers send `stand-down-complete`. Completed child sessions remain
  available afterward.
