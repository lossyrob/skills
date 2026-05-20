# GitHub PR Polling Guide

The PR helper scripts implement a practical decision model for:

- approval readiness,
- pending or failing checks,
- merge conflicts,
- branches that are behind the base branch,
- closed or already-merged PRs.

Use:

```bash
scripts/check-pr-ready.sh --pr 123 --require-review
```

or:

```powershell
.\scripts\check-pr-ready.ps1 -Pr 123 -RequireReview
```

Both scripts require `gh`.

## Exit codes

| Code | Meaning | Suggested agent behavior |
|---|---|---|
| `0` | Ready to merge, or already merged. | Continue or run merge action. |
| `10` | Waiting for review, checks, draft, or transient mergeability. | Keep polling. |
| `11` | Branch is behind the base branch. | Update branch, then restart loop. |
| `20` | CI/status checks are failing. | Inspect failures, fix, push, restart loop. |
| `21` | Merge conflicts detected. | Resolve conflicts, push, restart loop. |
| `22` | PR is closed without being merged. | Stop and report. |
| `23` | GitHub CLI/auth/API error. | Fix auth or command issue, then restart. |
| `24` | Review changes requested. | Address review feedback, push, restart. |

## Recommended loop

```bash
scripts/loop.sh \
  --check "scripts/check-pr-ready.sh --pr 123 --require-review" \
  --interval 300 \
  --timeout 21600 \
  --retry-exit-codes 10 \
  --stop-exit-codes 11,20,21,22,23,24 \
  --action "gh pr merge 123 --squash --delete-branch --match-head-commit \$(gh pr view 123 --json headRefOid --jq .headRefOid)"
```

PowerShell:

```powershell
$manifest = .\scripts\Start-LoopDetached.ps1 `
  -Name "pr-123-ready" `
  -CheckCommand ".\scripts\check-pr-ready.ps1 -Pr 123 -RequireReview" `
  -IntervalSeconds 300 `
  -TimeoutSeconds 21600 `
  -RetryExitCode 10 `
  -StopExitCode 11,20,21,22,23,24 `
  -ActionCommand "gh pr merge 123 --squash --delete-branch --match-head-commit (gh pr view 123 --json headRefOid --jq .headRefOid)" | ConvertFrom-Json

.\scripts\Wait-LoopDetached.ps1 -RunDir $manifest.runDir -PollIntervalSeconds 30
```

Detached PowerShell workers do not notify the agent session by themselves. `Wait-LoopDetached.ps1` is the attached quiet observer that wakes the agent when the PR watch becomes actionable or final. For background handoff instead, skip the waiter and give the user `$manifest.runDir` plus the exact `Get-LoopStatus.ps1` command.

## Decision table

The helper reads:

```bash
gh pr view <PR> --json state,isDraft,reviewDecision,mergeStateStatus,mergeable,headRefOid,url
```

| State | Exit | Meaning |
|---|---:|---|
| `state=MERGED` | `0` | Already merged. |
| `state=CLOSED` | `22` | Closed without merge. |
| `isDraft=true` or `mergeStateStatus=DRAFT` | `10` | Wait. |
| `mergeable=UNKNOWN` or `mergeStateStatus=UNKNOWN` | `10` | GitHub is still computing mergeability. |
| `mergeable=CONFLICTING` or `mergeStateStatus=DIRTY` | `21` | Conflicts require agent action. |
| `mergeStateStatus=BEHIND` | `11` | Branch update required. |
| `reviewDecision=CHANGES_REQUESTED` | `24` | Address review feedback. |
| `mergeStateStatus=UNSTABLE` | `20` | Checks are failing. |
| `mergeStateStatus=BLOCKED` and checks pending | `10` | Wait. |
| `mergeStateStatus=BLOCKED` and checks failed | `20` | Fix checks. |
| `mergeStateStatus=CLEAN` and review OK | `0` | Ready. |
| `mergeStateStatus=HAS_HOOKS` and review OK | `0` | Ready; server-side hooks may still run. |

When `--require-review` / `-RequireReview` is not set, `reviewDecision=null` is treated as ready because the repository may not require reviews. When review is explicitly required, only `APPROVED` is ready.

## Race-condition guard

Always merge with a head SHA guard:

```bash
gh pr merge 123 --squash --delete-branch \
  --match-head-commit "$(gh pr view 123 --json headRefOid --jq .headRefOid)"
```

This prevents merging a new commit that arrived after the loop checked readiness.

## Auto-merge alternative

If the repository supports GitHub auto-merge, prefer:

```bash
gh pr merge 123 --auto --squash --delete-branch
```

Use the loop skill when the agent needs to react to failures or conflicts rather than only wait for GitHub to merge.
