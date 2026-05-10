---
name: loop
description: Repeatedly run a check command or script on a configurable interval until a condition is met, a timeout is reached, or an actionable exit code is returned. Use when the user asks to loop, wait, poll, watch, retry, check periodically, wait for CI, wait for approval, wait for a service, or keep checking a PR before continuing.
compatibility: Includes Bash scripts for macOS/Linux/Git Bash and PowerShell scripts for Windows PowerShell 5.1 or PowerShell 7+. GitHub PR examples require the GitHub CLI.
---

# Loop Skill

Create a controlled loop that repeatedly runs a check command, waits between attempts, and lets the agent continue when a condition is met or when the check reports an actionable state.

Do **not** use this skill for explaining programming-language loop syntax. Use it when the user wants the agent to run commands over time, such as:

- "wait until the service is healthy"
- "poll the PR every 5 minutes"
- "retry this command until it succeeds"
- "watch for CI failures, merge conflicts, or approval"
- "keep checking until the deploy finishes"

## Safety model

This skill intentionally does **not** pre-approve shell tools. Loops can execute arbitrary user-supplied commands repeatedly, so the agent must be explicit about what will run.

Always:

1. Prefer a short, auditable check script over a long inline command.
2. Run `--dry-run` first for non-trivial or destructive workflows.
3. Use `--timeout` or `--max-tries` unless the user explicitly asks for an unbounded loop.
4. Route actionable states through `--stop-exit-codes` so the agent can fix issues before restarting the loop.
5. After every fix or update action, restart the loop rather than assuming the condition is still true.
6. Quote command strings for the shell that will execute them. For complex logic, write a temporary script and pass that script as the check command.
7. Stateful checks must be non-consuming: peek first, act next, and acknowledge only after the action succeeds.

## Runner selection

Use the runner that matches the active shell:

| Environment | Runner |
|---|---|
| macOS, Linux, Git Bash, WSL | `scripts/loop.sh` |
| Windows PowerShell 5.1 or PowerShell 7+ | `scripts/loop.ps1` |

## Core contract

### Bash

```bash
scripts/loop.sh --check "<command>" \
  --interval 30 \
  --timeout 3600 \
  [--action "<command>"] \
  [--ack "<command>"] \
  [--max-tries 20] \
  [--invert] \
  [--backoff-factor 2] \
  [--jitter-percent 10] \
  [--stable-for 5] \
  [--retry-exit-codes 1,10] \
  [--stop-exit-codes 11,20,21,22,23,24] \
  [--on-retry "<command>"] \
  [--lock-name "<name>"] \
  [--quiet] \
  [--dry-run]
```

### PowerShell

```powershell
.\scripts\loop.ps1 -CheckCommand "<command>" `
  -IntervalSeconds 30 `
  -TimeoutSeconds 3600 `
  [-ActionCommand "<command>"] `
  [-AckCommand "<command>"] `
  [-MaxTries 20] `
  [-Invert] `
  [-BackoffFactor 2] `
  [-JitterPercent 10] `
  [-StableForSeconds 5] `
  [-RetryExitCode 1,10] `
  [-StopExitCode 11,20,21,22,23,24] `
  [-OnRetryCommand "<command>"] `
  [-LockName "<name>"] `
  [-Quiet] `
  [-DryRun]
```

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Condition was satisfied and optional action succeeded. |
| `1` | General failure. |
| `2` | Invalid runner arguments. |
| `3` | Check command was not found or not executable. |
| `124` | Timeout or max tries reached. |

Checks can return domain-specific codes. Use `--stop-exit-codes` / `-StopExitCode` for codes that should stop the loop so the agent can act. For PR checks, use:

| Code | Meaning |
|---|---|
| `10` | Waiting for review, checks, or mergeability. |
| `11` | Branch is behind the base branch. |
| `20` | CI or required checks are failing. |
| `21` | Merge conflicts detected. |
| `22` | PR is closed without being merged. |
| `23` | GitHub CLI/auth/API error. |
| `24` | Review changes requested. |

## Loop environment

Every check, action, and on-retry command receives:

| Variable | Meaning |
|---|---|
| `LOOP_ATTEMPT` | Current attempt number, starting at `1`. |
| `LOOP_ELAPSED_SECONDS` | Elapsed wall-clock seconds since the loop started. |
| `LOOP_REMAINING_SECONDS` | Seconds until timeout, or `0` for unbounded loops. |

Action, ack, and on-retry commands additionally receive:

| Variable | Meaning |
|---|---|
| `LOOP_CHECK_EXIT_CODE` | Check exit code that triggered the action, ack, or retry hook. |

## Standard workflow

1. Identify the condition that should be checked.
2. Decide which exit codes mean "keep waiting" and which mean "agent must act".
3. For stateful checks, design a peek -> act -> ack flow:
   - Peek/check reads state and reports new actionable work without advancing markers.
   - Action handles that work.
   - Ack advances the marker only after the action succeeds.
4. Run a dry run.
5. Start the loop.
6. If the loop exits with an actionable code and no action is configured, fix the issue and restart the loop.
7. If the loop exits `0`, continue with the requested success action or final report.

## Examples

### Wait for a local service

```bash
scripts/loop.sh \
  --check "curl -fsS http://localhost:3000/health >/dev/null" \
  --interval 5 \
  --timeout 120 \
  --stable-for 5
```

```powershell
.\scripts\loop.ps1 `
  -CheckCommand "Invoke-WebRequest -UseBasicParsing http://localhost:3000/health | Out-Null" `
  -IntervalSeconds 5 `
  -TimeoutSeconds 120 `
  -StableForSeconds 5
```

### Retry a flaky command with backoff

```bash
scripts/loop.sh \
  --check "npm test" \
  --interval 2 \
  --backoff-factor 2 \
  --max-interval 60 \
  --max-tries 5
```

### Peek, act, then ack stateful work

Use this pattern for cursors, markers, checkpoints, offsets, "last seen" timestamps, queue leases, and other persisted state. The check must not advance the marker when it finds actionable work.

```bash
scripts/loop.sh \
  --check "./check-work.sh --marker marker.json --mode peek" \
  --retry-exit-codes 10 \
  --stop-exit-codes 31 \
  --action "./handle-work.sh" \
  --ack "./check-work.sh --marker marker.json --mode ack" \
  --interval 60 \
  --timeout 3600
```

```powershell
.\scripts\loop.ps1 `
  -CheckCommand ".\check-work.ps1 -Marker marker.json -Mode Peek" `
  -RetryExitCode 10 `
  -StopExitCode 31 `
  -ActionCommand ".\handle-work.ps1" `
  -AckCommand ".\check-work.ps1 -Marker marker.json -Mode Ack" `
  -IntervalSeconds 60 `
  -TimeoutSeconds 3600
```

If the action fails, ack does not run and the marker remains unchanged. If ack fails, the loop exits non-zero so the same work can be detected again after the ack problem is fixed.

### Watch a PR until it can be merged

Bash:

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
.\scripts\loop.ps1 `
  -CheckCommand ".\scripts\check-pr-ready.ps1 -Pr 123 -RequireReview" `
  -IntervalSeconds 300 `
  -TimeoutSeconds 21600 `
  -RetryExitCode 10 `
  -StopExitCode 11,20,21,22,23,24 `
  -ActionCommand "gh pr merge 123 --squash --delete-branch --match-head-commit (gh pr view 123 --json headRefOid --jq .headRefOid)"
```

If the loop exits with `20` or `21`, inspect the failure, fix CI or conflicts, push, and restart the loop. If it exits `11`, update the branch and restart the loop. If it exits `0`, the action has run.

## More detail

Read `references/guide.md` for full runner behavior and `references/pr-polling.md` for the PR decision table and recipes.
