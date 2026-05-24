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

$raw = (& $loopWait -RunDir $manifest.runDir -PollIntervalSeconds 30) -join [Environment]::NewLine
if (-not $raw) {
  throw "Wait-LoopDetached.ps1 returned no JSON; inspect with `$loopStatus before restarting: $($manifest.runDir)"
}
$result = $raw | ConvertFrom-Json
$result
```

Handle events by intent:

| Event | Implementer response |
|---|---|
| `classification` is `crashed` or `stalled` | Inspect with `$loopStatus`, report the worker fault/staleness, and restart this mode only after confirming the prior worker is not alive or has been intentionally stopped by manifest/status PID. |
| `review_detected` | Address the PR review comments, validate, push, then post a PR comment starting with `🐾 PAW Implementer: Review Addressed` and include the specific review information. Restart Review Response mode. |
| `approval_detected` | Fetch the latest +1 review body using the emitted `sourceUrl` / `sourceId` (e.g., `gh api` against the review or comment, or `gh pr view <pr-number> --repo <repo> --json reviews,comments`). A +1 may include non-blocking notes (nits, optional suggestions, follow-ups). For each note, decide: address it now (and if the resulting change is substantive, push and post `🐾 PAW Implementer: Re-review Requested` per the section below), or explicitly acknowledge it in the handoff/PR conversation so it is not silently dropped. Then enter PR Sentry mode. |
| `already_merged` | Task complete. |
| `script_or_github_api_error` | Fix the canonical script in `scripts\`, then restart the loop. |

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

$raw = (& $loopWait -RunDir $manifest.runDir -PollIntervalSeconds 30) -join [Environment]::NewLine
if (-not $raw) {
  throw "Wait-LoopDetached.ps1 returned no JSON; inspect with `$loopStatus before restarting: $($manifest.runDir)"
}
$result = $raw | ConvertFrom-Json
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

