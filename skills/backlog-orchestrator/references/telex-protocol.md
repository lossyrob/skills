# Telex protocol

How the orchestrator and worker sessions address each other and exchange messages. Read `telex skill`
once for the underlying holder/`wait` model; this file is the run-specific contract on top of it.

## Backend, run id, scope, tags

- **Backend (`<backend>`) — PIN IT ON EVERY COMMAND.** Pick the run's telex backend at start (e.g.
  `local` sqlite at `~/.telex/local.db`, or a named Postgres like `pg-rde-telex`) and pass
  `--backend <backend>` on **every** telex command — `attach`, `wait`, `status`, `inbox`, `send`,
  `reply`, `handle`, `address …`. Also set `$env:TELEX_BACKEND = "<backend>"` in every shell that runs
  telex. **Never rely on the default backend:** the user can change the default mid-run (e.g. to a
  Postgres backend), which silently routes the orchestrator's and workers' messages to a different store
  than their holders/waiters listen on — the address looks unoccupied, sends queue into the void, and
  waiters never wake. (This exact mismatch bit a real run.) All sessions in a run (orchestrator +
  workers) MUST share the same `<backend>`; capture it in the run manifest and inject it into every
  worker prompt.
- **Run id (`<runid>`):** a short slug you choose at run start, e.g. `rb-2026-06-17a`. It namespaces
  every address and tag so multiple backlog runs (and other people's telex traffic on the same store)
  never collide. The store is shared — **always scope your `address list` / `resolve` queries by this
  run** or you will see unrelated sessions.
- **Scope:** `backlog:<runid>` on every attach.
- **Tags:** `run:<runid>`, `repo:<owner/repo>`, `role:orchestrator|implementer|reviewer`,
  `issue:<n>` (workers only).

## Address scheme

| Session | Address | Description (for the directory) |
|---|---|---|
| Orchestrator | `orchestrator:<runid>` | `backlog orchestrator station for <owner/repo> run <runid>` |
| Implementer (issue n) | `impl:<runid>:issue-<n>` | `PAW implementer for issue #<n> (<owner/repo>) run <runid>` |
| Reviewer (issue n) | `review:<runid>:issue-<n>` | `PAW reviewer for issue #<n> (<owner/repo>) run <runid>` |

Each session exports `TELEX_ADDRESS` to **its own** address so every `send`/`reply` is repliable.

## Orchestrator station setup (phase 1)

Run the holder and each `wait` as **async background** shells that are **session-bound** (in Copilot
CLI terms: async with `detach: false` — never `detach: true`). The holder is long-lived but must die
with your session; a persistent holder would keep answering liveness for a dead session.

```powershell
$env:TELEX_ADDRESS = "orchestrator:<runid>"
$env:TELEX_BACKEND = "<backend>"
telex attach --backend "<backend>" --address "orchestrator:<runid>" `
  --description "backlog orchestrator station for <owner/repo> run <runid>" `
  --scope "backlog:<runid>" --tags "run:<runid>,repo:<owner/repo>,role:orchestrator"
```

**Startup barrier — confirm the holder is live before the first `wait`.** The holder and each `wait`
are separate processes; arming a `wait` before the holder is listening can race into a holder-gone exit.
After starting the holder, confirm it is occupied first: `telex status --backend "<backend>" --address
"orchestrator:<runid>"` (or `telex address show --backend "<backend>" ...`) — proceed only when
occupancy shows `occupied=true`. A persistent `occupied=false` for a holder you just started is the
signature of a **backend mismatch** (you queried a different `<backend>` than the holder attached to).

Then drive the **re-arm loop** at your turn level (not a shell `while` loop):

1. Start one async background `telex wait --backend "<backend>" --address "orchestrator:<runid>"`.
2. When that command **completes**, you are notified. Read its output and exit code:
   - exit 0 → a message was delivered (JSON on stdout). **Read and save it first; then start a fresh
     background `wait` as the next step** — do not bundle the re-arm into the same batch as heavy work
     (if that batch is interrupted you can lose the re-arm); then act on the saved message.
   - exit 3/4 → holder gone/hung → re-run `telex attach --backend "<backend>" ...`, then re-arm.
3. Disposition the message after acting (`telex handle --backend "<backend>" --id <id> --note "..."`).

Never wrap `telex wait` in an infinite shell loop — its **completion** is your wake signal, so one
single-shot wait per delivery, re-armed each turn.

> During phase 3 you are usually waiting on exactly one worker (sequential run), so a single armed
> `wait` is enough. If both an implementer and a reviewer might message you, one armed `wait` still
> suffices — telex buffers the second message and the next `wait` delivers it.

**Missed-wait recovery.** If a `wait` was interrupted or you suspect a delivery slipped by, do not assume
nothing arrived: check `telex inbox --backend "<backend>" --address "orchestrator:<runid>"` for queued
actionable messages, process them, then re-arm. A missing waiter is a transport gap, not proof of no
message. (If the inbox unexpectedly looks empty, re-check that you are on the run's `<backend>` — a
wrong-backend query returns an empty/foreign inbox.)

## Message vocabulary

All cross-session coordination uses these kinds. Put structured fields in `--metadata` (JSON) and a
human-readable summary in `--body`. Mark anything that needs the recipient to act with
`--requires-disposition` and an appropriate `--attention`.

| kind | direction | attention | meaning / required metadata |
|---|---|---|---|
| `review-ready` | impl → review | `next-checkpoint` | PR is open, **CI green**, ready for first review. `{pr, headSha, repo, issue}` |
| `review-posted` | review → impl | `next-checkpoint` | A GitHub review was submitted with blocking feedback. `{pr, verdict:"changes"}` |
| `review-approved` | review → impl | `next-checkpoint` | `🐾 PAW Review: +1` submitted; no blocking feedback (may carry non-blocking notes). `{pr, headSha}` |
| `rereview-requested` | impl → review | `next-checkpoint` | Implementer addressed feedback / pushed changes, **CI green**; please re-review. `{pr, headSha, summary}` |
| `merge-ready` | impl → orchestrator | `interrupt` | Reviewer approved (if a reviewer exists) **and** merge sentry reports ready. The implementer has **already posted its field report** on the issue (so the gate and the builder can read it). `{pr, headSha, fieldReportUrl}` |
| `blocked` | impl → orchestrator | `interrupt` | Hard blocker needing an orchestrator/human decision (issue amendment, repeated failure). `{pr?, reason}` |
| `process-feedback` | impl/review → orchestrator | `background` | At finish/stand-down: feedback on the **process/skill itself** (telex instructions, prompt, config friction; what worked; concrete suggested edits). Not disposition-required. |
| `human-review-pending` | orchestrator → impl, review | `interrupt` | Routed to human review; the orchestrator will **not** auto-merge. The implementer **keeps its sentry alive** (maintain merge-readiness, repair CI/conflicts) and **does not end**, until the human merges; the reviewer **stays armed** (it may get a late `rereview-requested`). `{pr, reason}` |
| `merged` | impl → orchestrator | `interrupt` | A PR the implementer was holding under `human-review-pending` has been **merged by the human**; the implementer requests stand-down. `{pr, mergeCommit?}` |
| `stand-down-merged` | orchestrator → impl, review | `interrupt` | The PR is merged (auto-merge, or human-merge after `human-review-pending`). Stop sentries/waits, post a brief field-report **addendum** if anything changed since merge-ready, clean up, end. `{pr}` |
| `stand-down-human` | orchestrator → impl, review | `interrupt` | Terminal stop **without** a pending merge — the issue is being abandoned / the PR closed / a blocker accepted, so there is nothing more to hold for. Stop, post a field-report addendum, clean up, end. `{pr?, reason}` |

Notes:
- Workers `send` with their own `TELEX_ADDRESS` as `from`, so your `reply` routes back automatically.
- Prefer `telex reply --backend "<backend>" --to-message <id>` to keep threads; the implementer's
  `merge-ready` thread is the natural place for your `human-review-pending` / `stand-down-*` reply.
- **Human-review handoff is deferred, not immediate.** When the gate routes an issue to human, you send
  `human-review-pending` (not a stand-down) and **advance** to the next issue; the implementer keeps its
  sentry alive so the PR stays mergeable while it waits for the builder. Your station's armed `wait` will
  later receive a `merged` from that implementer (whenever the builder merges) — only then do you send
  `stand-down-merged`. So a single armed `wait` may interleave the current issue's `merge-ready`/`blocked`
  with a past human-pended issue's `merged`; key off `from`/metadata to tell them apart.
- The marker contract (`🐾 PAW Review: +1`, etc.) still appears in the **GitHub** review/PR bodies for
  audit; telex carries the wakeup. Workers should not rely on polling those markers anymore.

## Injecting addresses into workers

Worker launch prompts (generated from the templates) must embed: the worker's own address, the
orchestrator address, the run id + scope + tags, the issue number, repo, and tier config. The worker
stands up **its own** holder + re-arm loop against its own address exactly as above. See
[lifecycle.md](lifecycle.md) for how the orchestrator fills and launches them.

## Cleanup

At end of run, retire the run's addresses so they drop from listings:

```powershell
telex address list --backend "<backend>" --scope "backlog:<runid>" --all
telex address retire --backend "<backend>" --address "<addr>"   # for each run address
```
