# Telex protocol (run-specific contract)

This file defines **only** the run-specific coordination contract for a backlog run: the addresses
sessions use, how they are scoped/tagged, and the message vocabulary they exchange.

**Telex mechanics are owned by the telex skill, not this file.** How to bind, receive, send, reply,
disposition, recover, and tear down changes with the telex binary and is documented by the installed
telex — so do not repeat it here. Every session in a run (orchestrator, implementer, reviewer) is a
**Copilot CLI session**, so each one loads the telex skill and follows the version-matched Copilot
workflow it prints:

```sh
telex skill            # underlying model + generic commands
telex copilot skill    # the Copilot push-delivery workflow (source of truth for our sessions)
```

Key consequence for this skill: on Copilot CLI, telex uses **push delivery** — you bind the in-session
bridge once and messages arrive as **turns**. You do **not** stand up a holder, run `telex wait`, or
re-arm a waiter (those are the generic/fallback path). Follow `telex copilot skill` for the exact
bind / receive / ack / send / detach syntax; this file assumes that workflow and layers the run
contract on top of it.

## Backend / shared store

All sessions in a run must reach each other, so they must share **one** telex store. Pick the run's
telex backend once at start (a local sqlite exchange is a fine default), capture it in the run
manifest, and inject the same value into every worker prompt. If you select a non-default backend,
apply it consistently across all sessions per the telex skill's backend guidance — do not let some
sessions fall back to a different default. Beyond "one shared store for the whole run", backend
selection and any pinning mechanics belong to the telex skill, not here.

## Run id, scope, tags

- **Run id (`<runid>`):** a short slug chosen at run start, e.g. `rb-2026-06-17a`. It namespaces every
  address and tag so multiple backlog runs (and unrelated telex traffic on a shared store) never
  collide. Always scope directory queries by this run so you do not see unrelated sessions.
- **Scope:** `backlog:<runid>` on every attach.
- **Tags:** `run:<runid>`, `repo:<owner/repo>`, `role:orchestrator|implementer|reviewer`,
  `issue:<n>` (workers only).

## Address scheme

Each session binds **its own** address (so every message it sends is repliable) and knows the
addresses of the peers it talks to.

| Session | Address | Directory description |
|---|---|---|
| Orchestrator | `orchestrator:<runid>` | `backlog orchestrator station for <owner/repo> run <runid>` |
| Implementer (issue n) | `impl:<runid>:issue-<n>` | `PAW implementer for issue #<n> (<owner/repo>) run <runid>` |
| Reviewer (issue n) | `review:<runid>:issue-<n>` | `PAW reviewer for issue #<n> (<owner/repo>) run <runid>` |

Bind, scope, and tag each address using the Copilot bind verb from `telex copilot skill` (it also
provisions the push bridge). After binding, the orchestrator receives worker messages as turns; there
is no waiter to arm and no occupancy barrier to clear.

## Message vocabulary

All cross-session coordination uses the message **kinds** below. This is the semantic contract; the
telex flags that carry it (kind, attention, disposition-required, structured metadata, body) come from
the telex skill / `telex send --help`. Put the structured fields in the message metadata and a
human-readable summary in the body, and mark anything the recipient must act on as
disposition-required with an appropriate attention level.

| kind | direction | attention | meaning / required metadata |
|---|---|---|---|
| `review-ready` | impl → review | `next-checkpoint` | PR is open, **CI green**, ready for first review. `{pr, headSha, repo, issue}` |
| `review-posted` | review → impl | `next-checkpoint` | A GitHub review was submitted with blocking feedback. `{pr, verdict:"changes"}` |
| `review-approved` | review → impl | `next-checkpoint` | `🐾 PAW Review: +1` submitted; no blocking feedback (may carry non-blocking notes). `{pr, headSha}` |
| `rereview-requested` | impl → review | `next-checkpoint` | Implementer addressed feedback / pushed changes, **CI green**; please re-review. `{pr, headSha, summary}` |
| `merge-ready` | impl → orchestrator | `interrupt` | Reviewer approved (if a reviewer exists) **and** merge sentry reports ready. The implementer has **already posted its field report** on the issue (so the gate and the builder can read it). `{pr, headSha, fieldReportUrl}` |
| `blocked` | impl → orchestrator | `interrupt` | Hard blocker needing an orchestrator/human decision (issue amendment, repeated failure). `{pr?, reason}` |
| `process-feedback` | impl/review → orchestrator | `background` | At finish/stand-down: feedback on the **process/skill itself** (telex instructions, prompt, config friction; what worked; concrete suggested edits). Not disposition-required. |
| `human-review-pending` | orchestrator → impl, review | `interrupt` | Routed to human review; the orchestrator will **not** auto-merge. The implementer **keeps its sentry alive** (maintain merge-readiness, repair CI/conflicts) and **does not end**, until the human merges; the reviewer **stays available** (it may get a late `rereview-requested`). `{pr, reason}` |
| `merged` | impl → orchestrator | `interrupt` | A PR the implementer was holding under `human-review-pending` has been **merged by the human**; the implementer requests stand-down. `{pr, mergeCommit?}` |
| `stand-down-merged` | orchestrator → impl, review | `interrupt` | The PR is merged (auto-merge, or human-merge after `human-review-pending`). Stop the sentry, post a brief field-report **addendum** if anything changed since merge-ready, clean up, end. `{pr}` |
| `stand-down-human` | orchestrator → impl, review | `interrupt` | Terminal stop **without** a pending merge — the issue is being abandoned / the PR closed / a blocker accepted, so there is nothing more to hold for. Stop, post a field-report addendum, clean up, end. `{pr?, reason}` |

Notes:
- Each session sends from its own bound address, so a reply routes back automatically. Prefer replying
  in-thread to keep a conversation together (the implementer's `merge-ready` thread is the natural
  place for your `human-review-pending` / `stand-down-*` reply).
- **Human-review handoff is deferred, not immediate.** When the gate routes an issue to human, you send
  `human-review-pending` (not a stand-down) and **advance** to the next issue; the implementer keeps its
  sentry alive so the PR stays mergeable while it waits for the builder. You will later receive a
  `merged` from that implementer (whenever the builder merges) — only then do you send
  `stand-down-merged`. So the current issue's `merge-ready`/`blocked` may interleave with a past
  human-pended issue's `merged`; key off the sender / metadata to tell them apart.
- The marker contract (`🐾 PAW Review: +1`, etc.) still appears in the **GitHub** review/PR bodies for
  audit; telex only carries the wakeup + pointer. Workers should not poll those markers.

## Injecting addresses into workers

Worker launch prompts (generated from the templates) must embed: the worker's own address, the
orchestrator address, the run id + scope + tags, the issue number, repo, tier config, and the run's
telex backend. The worker binds **its own** address and provisions its push bridge exactly as above,
following `telex copilot skill`. See [lifecycle.md](lifecycle.md) for how the orchestrator fills and
launches them.

## Cleanup

At end of run, tear down each session's telex binding using the detach verb from `telex copilot skill`,
and retire the run's addresses so they drop from directory listings (see `telex address --help`). The
mechanics live in the telex skill; the only run-specific part is that every `orchestrator:<runid>` /
`impl:<runid>:*` / `review:<runid>:*` address should be retired.
