# Implementer Lifecycle

The implementer owns the PR from implementation through merge-readiness, but does not merge the PR unless explicitly instructed elsewhere. Its job after opening the PR is to keep it healthy until GitHub reports it has been merged.

## Implementation mode

Use the requested PAW workflow and repository/worktree guidance from the launch prompt. Before starting, create TODOs for the lifecycle transitions below so a long session cannot lose the mode contract.

After creating the PR, record the PR number and exact `owner/repo` for the PR. Use that repo value for the lifecycle loop `-Repo` argument; the launch prompt does not need to know the repo in advance.

Creating the PR is the handoff into Review Response mode, not the end of the implementer lifecycle. Before sending a final PR-ready response, mark Review Response mode in progress and start the canonical review-response loop below, or run the checker once and handle the returned event if review feedback or approval is already present. Report the active loop identity or the actionable event being handled; do not leave Review Response mode pending after PR creation.

## Review Response mode

Watch for PAW reviews and approvals:

```powershell
$manifest = & $loopDetached `
  -Name "paw-impl-review-response-<pr-number>" `
  -CheckCommand "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$loopScripts\impl-review-response-check.ps1`" -Repo <repo> -PullRequest <pr-number> -GhUser <gh-user>" `
  -IntervalSeconds 60 `
  -TimeoutSeconds 43200 `
  -RetryExitCode 10 `
  -StopExitCode 23 `
  -Quiet | ConvertFrom-Json

$result = Receive-LifecycleLoopResult -LoopWait $loopWait -LoopStatus $loopStatus -Manifest $manifest -PollIntervalSeconds 30
$result
```

Handle events by intent:

| Event | Implementer response |
|---|---|
| `classification` is `crashed` or `stalled` | Inspect with `$loopStatus`, report the worker fault/staleness, and restart this mode only after confirming the prior worker is not alive or has been intentionally stopped by manifest/status PID. |
| `review_detected` | Address the PR review comments, validate, push, then post a PR comment starting with `🐾 PAW Implementer: Review Addressed` and include the specific review information. Restart Review Response mode. |
| `approval_detected` | **Do NOT enter PR Sentry immediately.** Follow [Handling approval](#handling-approval) — read the +1 review body, triage every note, then transition. |
| `already_merged` | Task complete. |
| `script_or_github_api_error` | Fix the canonical script in `scripts\`, then restart the loop. |

### Handling approval

`approval_detected` means the reviewer is no longer blocking, but a `🐾 PAW Review: +1` body almost always carries non-blocking notes (nits, optional suggestions, follow-up ideas, deferred questions). Treating `+1` as a bare go-ahead silently drops reviewer signal that was posted on the assumption you would read it. The following steps are **mandatory** before entering PR Sentry mode:

1. **Fetch the +1 review body** using the emitted `sourceUrl` / `sourceId`. For a PR-level summary of all reviews and comments:

   ```powershell
   gh pr view <pr-number> --repo <repo> --json reviews,comments
   ```

   For the specific review surfaced by the event, hit its API URL directly (e.g., `gh api $sourceUrl`).

2. **Enumerate every note in the body** — nit, suggestion, follow-up, optional cleanup, open question. A note can sit anywhere in the body, not just at the end. If the body genuinely has no notes (just the marker line, or the marker plus a "thanks" sentence), state that explicitly in your response and skip to step 4.

3. **For each note, pick exactly one branch and execute it before transitioning.** Mixing branches across notes within the same review is fine and common.

   | Branch | When to use | What to do |
   |---|---|---|
   | **A. Quick fix → push → PR Sentry** | The note is a small, mechanical change (typo, lint warning, comment wording, trivial refactor, single-line correction, doc tweak) where another reviewer pass would add no value. | Make the change, validate locally, push. Post a brief PR comment noting what you fixed (one line is fine — no marker required). Enter PR Sentry. **Do NOT** post `🐾 PAW Implementer: Re-review Requested`; that would burn a review cycle on a nit. |
   | **B. Substantive fix → push → Re-review** | The note prompts a change large enough that the reviewer would benefit from another look (logic change, new or expanded test, refactor that crosses files, observable behavior change, security-relevant edit). | Make the change, validate, push, post `🐾 PAW Implementer: Re-review Requested` per [Requesting re-review after approval](#requesting-re-review-after-approval), and **restart Review Response mode**. Do NOT enter PR Sentry — the head SHA has moved and the prior approval no longer covers it. |
   | **C. Acknowledge and defer** | The note is a follow-up idea or out-of-scope suggestion you are intentionally not addressing in this PR. | Post a brief PR comment explicitly acknowledging the note and stating why it is deferred (link a follow-up issue when one exists). Enter PR Sentry. Do NOT silently drop it. |

   When in doubt between A and B, default to B. Re-review is cheap; missed regressions on top of a stale approval are not.

4. **Transition to PR Sentry mode** only after every note has been handled by one of the branches above, or after explicitly confirming the body has no notes. Report in your summary which branches you used (e.g., "Triaged 3 notes: 2 quick fixes pushed, 1 deferred to follow-up issue. Entering PR Sentry.") so the user can audit the decision.

Skipping from `approval_detected` straight to PR Sentry without performing steps 1–3 is a contract violation. If you find yourself about to start the PR Sentry detached worker right after seeing `approval_detected` in the waiter output, stop and run steps 1–3 first.

## PR Sentry mode

Watch merge-readiness continuously until the PR is merged:

```powershell
$manifest = & $loopDetached `
  -Name "paw-impl-merge-sentry-<pr-number>" `
  -CheckCommand "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$loopScripts\impl-merge-sentry-check.ps1`" -Repo <repo> -PullRequest <pr-number> -GhUser <gh-user>" `
  -IntervalSeconds 60 `
  -TimeoutSeconds 43200 `
  -RetryExitCode 10 `
  -StopExitCode 23 `
  -Quiet | ConvertFrom-Json

$result = Receive-LifecycleLoopResult -LoopWait $loopWait -LoopStatus $loopStatus -Manifest $manifest -PollIntervalSeconds 30
$result
```

`ready_to_merge` is a steady state. The first ready state for a head SHA exits once so the agent can report it, then the same-head ready state becomes non-terminal after PR Sentry is restarted. Keep the sentry alive so later CI failures, base-branch changes, reviews, or merge conflicts are caught before the developer merges.

| Event | Implementer response |
|---|---|
| `classification` is `crashed` or `stalled` | Inspect with `$loopStatus`, report the worker fault/staleness, and restart this mode only after confirming the prior worker is not alive or has been intentionally stopped by manifest/status PID. |
| `ready_to_merge` | Report that the PR is currently ready, restart PR Sentry, and do not merge. |
| `ci_failed`, `merge_conflict`, `changes_requested`, `merge_blocked` | Repair, validate, push, and restart the appropriate sentry. |
| `post_approval_review_received` | Switch back to Review Response mode and address the new reviewer feedback. |
| `already_merged` | Task complete. |
| `closed_unmerged` | Stop and report the terminal state. |
| `script_or_github_api_error` | Fix the canonical script in `scripts\`, then restart the loop. |

## Requesting re-review after approval

After `🐾 PAW Review: +1`, request a new review when the PR receives substantive changes, builder-review-driven repairs, or complex merge-conflict resolution that would benefit from reviewer judgment.

Post a PR comment starting with:

```text
🐾 PAW Implementer: Re-review Requested
```

Include the reason, current head SHA, and concise summary of changed behavior. Then return to Review Response mode so the implementer notice the next review or approval.

