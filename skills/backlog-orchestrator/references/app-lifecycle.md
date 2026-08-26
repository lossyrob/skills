# App per-issue execution (phase 3)

Sequential. Process `issues` in `position` order; exactly one issue is actively driven at a time. For
each issue, drive it to a terminal advancement state (`merged`, `human-review`, or `blocked`), then
advance. App child sessions held for earlier human-review PRs may remain alive while a later issue is
active.

## Resolve the app context once

Read `project_id` and the orchestrator's `project_session_id` from workspace context and persist them
in `run_meta`. The target project owns the repository and supplies isolated worktrees for child
sessions. Use the app session tools described in [app-protocol.md](app-protocol.md); do not launch
terminal processes or create worktrees manually.

## The per-issue loop

For the current issue `#n` with its manifest row:

1. **Mark running.** `UPDATE issues SET status='running' WHERE issue_number=n;` and set the issue's
   lifecycle `todo` to `in_progress`.

2. **Create reviewer first when enabled.** Render
   [app-reviewer-prompt.md](../templates/app-reviewer-prompt.md) with `{{runid}}`, `{{repo}}`,
   `{{issue}}`, `{{orchestratorSessionId}}`, `{{ghNote}}`, `{{baseBranch}}`, and
   `{{reviewConfig}}`, then create the reviewer and capture its returned session id. Prompt files are
   unnecessary because `create_session.kickoff` accepts the full prompt.

   Reviewer:

   ```text
   create_session({
     project_id: <target project id only when different from current>,
     name: "<runid> review #<n>",
     workspace_type: "worktree",
     execution_location: "local",
     coordinate_with_creator: true,
     kickoff: {
       prompt: <rendered reviewer prompt>,
       agent: "PAW-Review",
       mode: "autopilot",
       model: <review model only when pinned>
     }
   })
   ```

3. **Create the implementer.** Render
   [app-implementer-prompt.md](../templates/app-implementer-prompt.md) only after the reviewer creation
   returns. Fill `{{runid}}`, `{{repo}}`, `{{issue}}`, `{{issueTitle}}`,
   `{{orchestratorSessionId}}`, `{{ghNote}}`, `{{baseBranch}}`, `{{reviewerSessionId}}` (or `none`),
   `{{reviewerPresent}}`, `{{implConfig}}`, `{{prTitleFormat}}` (from the resolved issue row), and
   `{{workstreamId}}` (use `<runid>-<n>`), then create it:

   ```text
   create_session({
     project_id: <target project id only when different from current>,
     name: "<runid> impl #<n>",
     workspace_type: "worktree",
     execution_location: "local",
     coordinate_with_creator: true,
     kickoff: {
       prompt: <rendered implementer prompt>,
       mode: "autopilot",
       model: <implementation model only when pinned>
     }
   })
   ```

   Omit `base_branch` when the project default is correct. Pass the issue's explicit non-default base
   only when the work truly depends on that branch. Persist both returned ids on the issue row. If a
   reviewer exists, immediately send it this app-native event with `delivery_mode: "immediate"` and
   `mode: "autopilot"`:

   ```text
   BACKLOG_EVENT
   run_id: <runid>
   kind: peer-registered
   issue: <n>
   pr: none
   head_sha: none
   field_report_url: none
   reason: none
   event_id: peer-registered:<implementer session id>

   Implementer session id: <implementer session id>
   ```

   The reviewer starts first so it is ready before the PR, but it may finish its initial turn and go
   idle before registration arrives. The immediate native message wakes it. The implementer is a
   general session that loads `paw-lite` from the prompt; do not launch it as the `PAW` agent.

   Review handoffs follow the receipt/replay guard in [app-protocol.md](app-protocol.md): the
   implementer expects `review-received`, uses one five-minute recovery wake, and replays an
   unacknowledged deterministic event id at most once.

4. **Wait for this issue's terminal event** (`merge-ready` or `blocked`). Native child-to-parent
   messages arrive as cross-session turns. A `merged` from a past human-pended issue may interleave;
   handle it per step 5, then resume the current issue. Log non-terminal `process-feedback` messages.
   Verify each message's run id, issue, and sender session id against the manifest.

   Do not poll with `get_session`. Idle notifications are informational. Use `get_session` once only
   when a child is unexpectedly silent, failed, or awaiting plan approval.

5. **Branch on the event kind:**

   - **`merge-ready`** -> the implementer has already posted its **field report** on the issue. Read it,
     then run the **merge gate** ([merge-gate.md](merge-gate.md)). It returns:

     - `merge` -> squash-merge and verify issue closure. Send `stand-down-merged` to the implementer
       and reviewer with `send_session_message`, immediate delivery, autopilot mode. Mark
       `issues.status='merged'` and set `pr_number`.
     - `human-review` -> do not merge or archive workers. Send `human-review-pending` to both child
       sessions so the implementer's recurring sentry remains active and the reviewer remains
       available. Mark `issues.status='human-review'`, set `pr_number`, record the reason and well-lit
       bet, then advance.

     **Always record deferred work.** Insert every item from the gate's `DEFERRED:` list into the
     `deferred` table with `status='open'`. For a human-disposition issue that skipped the subagent,
     harvest the field report's Deferred section directly.

   - **`merged`** (from a previously human-pended implementer) -> verify the PR is merged with
     `gh pr view`. Send `stand-down-merged` to that issue's implementer and reviewer, mark the issue
     merged, and log the event. Then return to the current issue.

   - **`blocked`** -> record and surface the blocker. Per the user's directive, mark the issue blocked,
     send `stand-down-human` to its workers, and advance. Pause the whole run only if the user requests
     it.

6. **Archive after stand-down.** Each worker responds with `stand-down-complete` after clearing its
   automation and posting any required feedback/addendum. Verify the sender id, then call
   `archive_session` for that child. Do not archive a human-review worker merely because the issue is
   terminal for advancement.

   If `archive_session` fails with a worktree/process file lock, wait for the child to be idle and
   retry once. A second failure is a cleanup blocker: retain the session id and error in the ledger,
   surface it in the final report, and leave the app-managed worktree untouched.

   A stand-down acknowledgement can arrive while a later issue is running. Archive it when received,
   update the ledger, and resume the active issue.

7. **Advance.** Mark the issue lifecycle `todo` done. Move to the next pending issue by `position`.
   When no issues remain, gate the backlog-pass report on:

   - no `deferred.status='open'` rows;
   - every merged/blocked issue's child sessions acknowledged and were archived;
   - human-review sessions remain intentionally alive and are listed in the final report.

   Run deferred triage ([reporting.md](reporting.md)), then produce the final backlog report. If any
   human-review holds remain, the orchestrator session must stay resident after reporting. The run is
   fully closed only after every held PR is merged or abandoned, its workers acknowledge stand-down,
   and its child sessions are archived.

## Stand-down is the worker's true terminus

Workers do not end at PR creation or `merge-ready`. The implementer posts its field report and enables
its recurring sentry automation before signalling ready.

- **Auto-merge:** merge, send `stand-down-merged`, wait for `stand-down-complete`, archive.
- **Human review:** send `human-review-pending` and advance. The implementer keeps the sentry automation
  active until the builder merges. It then sends `merged`; send `stand-down-merged`, wait for
  completion, and archive.
- **Abandoned/blocked:** send `stand-down-human`, wait for completion, and archive.

Several human-review sessions may remain idle and unarchived while later issues run. This is expected.
Their recurring implementer automation maintains merge readiness; native messages wake reviewers only
when re-review is needed.

## Crash / silence posture

No active liveness polling. If a worker is unexpectedly silent:

1. Inspect it once with `get_session`.
2. If it is awaiting a plan, read the plan and use `respond_to_session_plan` only when it matches the
   assignment; workers should normally be launched in autopilot.
3. If it failed, inspect GitHub and its sibling session before relaunching to avoid duplicate PRs or
   reviews.
4. Send a corrective immediate message when the existing child is recoverable. Otherwise decide with
   the user whether to relaunch or mark the issue blocked.
