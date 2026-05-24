# Reviewer Lifecycle

The reviewer owns PR discovery, high-signal review, and follow-up after approval. Reviewer sessions submit real GitHub PR reviews and keep watching until the PR is merged.

## Discovery mode

Wait for the implementation PR:

```powershell
$manifest = & $loopDetached `
  -Name "paw-review-pr-discovery-<issue-number>" `
  -CheckCommand "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$loopScripts\review-pr-discovery-check.ps1`" -Repo <repo> -Issue <issue-number> -GhUser <gh-user>" `
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

If the issue has base-branch guidance, include `-BaseBranch <base-branch>` in the check command.

| Event | Reviewer response |
|---|---|
| `classification` is `crashed` or `stalled` | Inspect with `$loopStatus`, report the worker fault/staleness, and restart this mode only after confirming the prior worker is not alive or has been intentionally stopped by manifest/status PID. |
| `pr_found` | Use the emitted `pullRequest` value and review that PR. |
| `weak_pr_references_only`, `no_pr_found` | Keep waiting. |
| `multiple_closing_pr_references`, `multiple_pr_candidates` | Inspect candidates; fix the canonical script if the detection logic is wrong. |
| `script_or_github_api_error` | Fix the canonical script in `scripts\`, then restart discovery. |

## Review mode

Review the current PR head with the requested PAW review strategy. Use a worktree so the main checkout remains untouched.

Submit an actual GitHub PR review, not a PR comment or issue/timeline comment substitute. Use a body-only review unless inline anchors are validated against the current PR diff:

```powershell
gh pr review <pr-number> --repo <repo> --comment --body-file <review-body-file>
```

If there are no remaining comments, make the review body start with:

```text
🐾 PAW Review: +1
```

Use that exact marker only when approving/no blocking feedback remains. When feedback remains, do not quote or negate the marker phrase; say "not ready to approve" or similar instead.

A `🐾 PAW Review: +1` review may still include non-blocking notes — nits, optional suggestions, or follow-up ideas — when no blocking issue remains. Label each such note clearly so the implementer can triage it quickly; recommended prefixes are `nit:`, `optional:`, or `follow-up:`. The implementer is contractually required to read the full +1 body and decide whether to address each note before merge or acknowledge it explicitly, so notes should be concrete enough to act on without a follow-up round trip.

Avoid `--request-changes` while authenticated as the PR author because GitHub rejects self-requested changes. If a non-author reviewer account is active and allowed, `--request-changes` or `--approve` may be used. After any review command, verify the latest review by the authenticated user:

```powershell
gh pr view <pr-number> --repo <repo> --json reviews,reviewDecision
```

After posting the first review, enter Follow-up Sentry mode.

## Follow-up Sentry mode

Watch for addressed reviews, explicit re-review requests, unreviewed head changes, or merge:

```powershell
$manifest = & $loopDetached `
  -Name "paw-review-follow-up-<pr-number>" `
  -CheckCommand "pwsh -NoProfile -ExecutionPolicy Bypass -File `"$loopScripts\review-addressed-check.ps1`" -Repo <repo> -PullRequest <pr-number> -GhUser <gh-user>" `
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

| Event | Reviewer response |
|---|---|
| `classification` is `crashed` or `stalled` | Inspect with `$loopStatus`, report the worker fault/staleness, and restart this mode only after confirming the prior worker is not alive or has been intentionally stopped by manifest/status PID. |
| `review_addressed`, `rereview_requested`, `head_changed_after_latest_review` | Inspect the new state, re-review as needed, submit a new PR review if there is feedback, or reaffirm with a PR review starting `🐾 PAW Review: +1`. Restart Follow-up Sentry mode. |
| `already_merged` | Task complete. |
| `closed_unmerged` | Stop and report the terminal state. |
| `script_or_github_api_error` | Fix the canonical script in `scripts\`, then restart the loop. |

