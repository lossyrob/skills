# Per-issue execution (phase 3)

Sequential. Process `issues` in `position` order; exactly one issue is `running` at a time. For each
issue, drive it to a terminal state (`merged`, `human-review`, or `blocked`), then advance.

## Resolve the launcher once

```powershell
$launch = (Get-ChildItem "$env:USERPROFILE\.copilot" -Recurse -Filter 'Launch-CopilotTerminal.ps1' `
  -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
# Typical: ...\installed-plugins\lossyrob-skills\lossyrob-skills\skills\launch-copilot-terminal\Launch-CopilotTerminal.ps1
```

`repo_path` (local checkout) and `repo` (`owner/repo`) come from `run_meta`. Workers create their own
worktrees from `repo_path`, so launch them with `-Cwd <repo_path>`.

## The per-issue loop

For the current issue `#n` with its manifest row:

1. **Mark running.** `UPDATE issues SET status='running' WHERE issue_number=n;` and set the issue's
   lifecycle `todo` to `in_progress`.

2. **Generate prompt files.** Fill the templates and write each to a **UTF-8** file (long prompts →
   use `-PromptFile`). Substitute every `{{...}}` placeholder:
   - `templates/implementer-prompt.md` → `<session files>\prompts\impl-<n>.md`
   - `templates/reviewer-prompt.md` → `<session files>\prompts\review-<n>.md` (only if `reviewer_enabled`)

   Required substitutions (both): `{{runid}}`, `{{repo}}`, `{{issue}}`, `{{telexBackend}}` (from
   `run_meta`), `{{orchestratorAddress}}`, `{{ghNote}}` (the user's gh-account guidance), `{{baseBranch}}`.
   Implementer also: `{{implAddress}}`, `{{reviewAddress}}` (or a "no reviewer" note), `{{reviewerPresent}}`,
   `{{implConfig}}`, `{{workstreamId}}` (use `<runid>-<n>`). Reviewer also: `{{reviewAddress}}`,
   `{{implAddress}}`, `{{reviewConfig}}`.

   Write prompt files as UTF-8 (`Set-Content -Encoding utf8` or Python `Path.write_text(...,
   encoding="utf-8")`) to avoid mojibake in the launched session.

3. **Launch reviewer first (if enabled), then implementer.** telex buffers messages to not-yet-attached
   addresses (`queued-unoccupied`), so order is not strictly racey, but launching the reviewer first
   means it is already waiting when `review-ready` arrives.

   ```powershell
   if ($reviewerEnabled) {
     & $launch -Title "review #<n>" -Color purple -Cwd "<repo_path>" `
       -PromptFile "<...>\review-<n>.md" -CopilotArgs @("--allow-all","--agent","PAW-Review")
   }
   & $launch -Title "impl #<n>" -Color green -Cwd "<repo_path>" `
     -PromptFile "<...>\impl-<n>.md" -CopilotArgs @("--allow-all")
   ```

   The **reviewer launches as the `PAW-Review` custom agent** (`--agent PAW-Review`) so it runs the real
   PAW Review workflow + its review guardrails; its prompt authorizes autonomous review submission
   (overriding the agent's pending/human-submit Human Control Point) so the telex handshake works. The
   **implementer does NOT use `--agent PAW`** — its `Workflow Identity` is `paw-lite` (a lighter skill),
   whereas the `PAW` agent runs the full spec→…→pr workflow; paw-lite is loaded via the prompt instead.
   Append `"--model",<model>` to either when the issue config pins a session model.

4. **Wait for this issue's terminal message** on your station (`merge-ready` or `blocked`). You already
      have a `telex wait` armed (telex-protocol.md). A `merged` from a **past** human-pended issue may also
      arrive here (handle it per step 5, then resume waiting on the current issue). Non-terminal messages
      (`status`, `process-feedback`) are not actionable — log them to the ledger and keep waiting.
      Disposition/ignore any stray messages not from this run's workers.

5. **Branch on the message kind:**

   - **`merge-ready`** → the implementer has already posted its **field report** on the issue (read it —
     it is a first-class input to the gate and may already name the forks). Run the **merge gate**
     ([merge-gate.md](merge-gate.md)). It returns one of:
     - `merge` → squash-merge, verify issue closed, then **stand down merged**:
       ```powershell
       gh pr merge <pr> --repo <repo> --squash --delete-branch
       ```
       Reply in the `merge-ready` thread (`telex reply --backend "<backend>" --to-message <id> ...`)
       with `stand-down-merged` (metadata `{pr}`), and also `telex send --backend "<backend>"`
       `stand-down-merged` to `review:<runid>:issue-<n>` if a reviewer exists.
       `UPDATE issues SET status='merged', pr_number=<pr> ...`.
     - `human-review` → do **not** merge, and do **not** stand the workers down yet. Reply
       `human-review-pending` (metadata `{pr, reason}`) so the implementer **keeps its sentry alive** and
       holds the PR mergeable until the builder merges; send the same to the reviewer so it stays armed.
       `UPDATE issues SET status='human-review', pr_number=<pr> ...`. Record the reason and the subagent's
       well-lit bet in the ledger ([reporting.md](reporting.md)). Then **advance** (step 7) — the held
       implementer will message you `merged` later, out of band.

     **Always record deferred work (both outcomes).** Insert every item from the gate's `DEFERRED:` list
     into the `deferred` table (status `open`) — see [reporting.md](reporting.md). For a human-disposition
     issue that skipped the subagent, harvest the field report's Deferred section yourself. This harvest is
     unconditional; skipping it is the main way carry-forward work is lost.

   - **`merged`** (from a previously human-pended implementer) → the builder merged that issue's PR.
     Verify (`gh pr view <pr> --json state,mergedAt`), then send `stand-down-merged` to that issue's
     implementer (reply in-thread) and reviewer. `UPDATE issues SET status='merged' WHERE issue_number=<that issue>;`
     log `merged` in the ledger. This can arrive at any time (even while a later issue is running) — handle
     it whenever it lands, then return to what you were doing.

   - **`blocked`** → record the blocker in the ledger, **surface it to the user** in your next reply
     (plain text), and per the user's directive **move on**: mark `status='blocked'`, send a
     `stand-down-human` (terminal stop — the issue is not proceeding to a merge), and advance. Only pause
     the whole run if the user tells you to.

6. **Disposition** the worker message (`telex handle --backend "<backend>" --id <id> --note "<terminal outcome>"`).

7. **Advance.** Mark the issue's lifecycle `todo` `done`. Move to the next `pending` issue by
   `position`. When no issues remain, **gate run-completion on deferred work**: the run is not complete
   while `SELECT COUNT(*) FROM deferred WHERE status='open'` > 0 — run the deferred triage routine
   ([reporting.md](reporting.md)) with the builder to drive every open item to a terminal disposition
   (filed/folded/skipped/done/moot), then produce the final report and run telex cleanup.

## Stand-down is the worker's true terminus (and it is deferred for human review)

Workers do not end at PR creation or at `merge-ready`. The implementer posts its **field report at
merge-ready** (so the gate and the builder can read it), then keeps its merge sentry / re-review waits
alive until it receives a `stand-down-*` from you.

- **Auto-merge:** you merge, then send `stand-down-merged` immediately.
- **Human review:** you send `human-review-pending` (not a stand-down). The implementer keeps its sentry
  alive — repairing CI/conflicts so the PR stays mergeable — until the **builder** merges. When the
  builder merges, the implementer detects it and sends you `merged`; only then do you send
  `stand-down-merged`. If instead the issue is abandoned (PR closed, blocker accepted, builder says stop),
  send `stand-down-human` to stop the worker without a merge.

On stand-down the worker posts a brief field-report **addendum** if anything changed since merge-ready
(e.g. post-routing conflict repairs), cleans up its worktree, and ends. Always send a stand-down on every
terminal branch — a sentry left without one will poll indefinitely. Because human-review stand-down is
deferred, several past implementers may be idling in sentry mode while you run later issues; that is
expected (their idle holders survive, and the durable backend loses no `merged` message).

## Crash / silence (v1 posture)

No active liveness monitoring in v1. If you suspect a worker died (no message for a long time), you may
manually inspect `telex address list --backend "<backend>" --scope "backlog:<runid>"` (liveness grade) and the PR state via
`gh`, then decide with the user whether to relaunch or mark the issue blocked. Do not build this into
the autonomous loop for v1.
