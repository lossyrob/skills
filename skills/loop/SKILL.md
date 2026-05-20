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
2. For PowerShell, default to `Start-LoopDetached.ps1`. Only call `loop.ps1` attached when you have positive evidence the loop is short-lived or the user explicitly wants live terminal output.
3. Run `--dry-run` first for non-trivial or destructive workflows.
4. Use `--timeout` or `--max-tries` unless the user explicitly asks for an unbounded loop.
5. Route actionable states through `--stop-exit-codes` so the agent can fix issues before deciding whether to restart or finish.
6. Decide whether the workflow is single-shot or watch-until-terminal before starting the loop.
7. Quote command strings for the shell that will execute them. For complex logic, write a temporary script and pass that script as the check command.
8. Stateful checks must be non-consuming: peek first, act next, and acknowledge only after the action succeeds.

## Stateful check rule

If follow-up work requires agent reasoning or dynamic action, the check must be non-consuming. It may emit an event ID, details, or an artifact path and then exit with a stop/action code, but it must not advance markers or mutate source state. Leave `--action` / `-ActionCommand` unset so the loop stops, then the agent can inspect details, edit code, validate, push, reply, or otherwise complete the response. After that succeeds, run an explicit ack command. Restart the loop only when the workflow is meant to keep watching.

Consuming checks are only safe for automation-only workflows where the check script itself fully handles the work atomically before marking it done. That is not appropriate for PR review response, CI repair, merge-conflict repair, or any workflow where the agent must reason about what happened.

| Pattern | Safe when | Example |
|---|---|---|
| Non-consuming check | The agent must act dynamically afterward. | PR review arrives, CI fails, merge conflict appears. |
| Consuming check | The script fully completes the work atomically without agent reasoning. | Delete expired temp files and mark cleanup complete. |

## Agent todo guardrail

For agent-reasoned stateful loops, create todos before starting the loop or immediately after it exits with an actionable code. The todos should make the acknowledgement step explicit so it is not lost during a long repair or review-response flow:

1. Inspect the emitted event details or artifact.
2. Handle the event and complete any required validation, push, reply, or external update.
3. Run the exact ack command that advances the marker.
4. Restart the loop only for watch-until-terminal workflows; otherwise continue with the next instruction or final response.

This guardrail is not required for simple stateless waits, such as polling a local service until it is healthy.

## Runner selection

Use the runner that matches the active shell. For PowerShell, detached mode is the default because attached terminal output can become stale from the agent's point of view if the loop lives longer than expected.

| Environment | Runner |
|---|---|
| macOS, Linux, Git Bash, WSL | `scripts/loop.sh` |
| Windows PowerShell 5.1 or PowerShell 7+ | `scripts/Start-LoopDetached.ps1` plus `scripts/Get-LoopStatus.ps1` |
| Short-lived/debug PowerShell exception | `scripts/loop.ps1` attached, only when quick live output is more important than durable state |

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

### PowerShell default: detached

Use this path unless the loop is known to be short-lived:

```powershell
.\scripts\Start-LoopDetached.ps1 `
  -Name "watch-name" `
  -CheckCommand "<command>" `
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
  [-Force] `
  [-DryRun]
```

Observe progress with:

```powershell
$manifest = .\scripts\Start-LoopDetached.ps1 -Name "watch-name" -CheckCommand "<command>" | ConvertFrom-Json
.\scripts\Get-LoopStatus.ps1 -RunDir $manifest.runDir
```

The detached launcher writes a run directory containing `manifest.json`, `loop.pid`, `stdout.log`, `stderr.log`, `last-result.json`, `heartbeat.json`, and immutable event files under `events\`. `manifest.json` records both the PID and process start time so status checks can reject recycled PIDs. Use `-Quiet` to suppress loop chatter in redirected logs. Use `-Force` only when intentionally reusing an explicit `-RunDir` whose prior loop is known to be stopped. Detached mode is durable state, not automatic fire-and-forget: keep checking `Get-LoopStatus.ps1` as repeated short status commands until the user-requested wait/watch condition is terminal, actionable, stalled, or crashed unless the user explicitly asked to leave the loop running in the background. Do not wrap status checks in another long-running attached shell loop.

### PowerShell attached exception

Only use attached mode when the loop is expected to complete quickly, the user explicitly wants live terminal output, or you are debugging the check command. If duration is uncertain, do **not** use attached mode. Attached loops can become stale from the agent's perspective if they remain alive too long.

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
  [-LastResultPath ".loop\last-result.json"] `
  [-HeartbeatPath ".loop\heartbeat.json"] `
  [-EventDir ".loop\events"] `
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
2. Decide whether this is a single-shot loop or a watch-until-terminal loop.
3. Decide which exit codes mean "keep waiting" and which mean "agent must act".
4. For stateful checks, design a peek -> act -> ack flow:
   - Peek/check reads state and reports new actionable work without advancing markers.
   - If the agent must reason, the loop exits with a stop/action code and the agent handles the work outside the runner.
   - If the work is automation-only, `ActionCommand` may handle it inside the runner.
   - Ack advances the marker only after the agent or action succeeds.
5. For agent-reasoned stateful checks, create todos that include the exact ack command and whether to restart or finish after ack.
6. Run a dry run.
7. Start the loop. For PowerShell, use `Start-LoopDetached.ps1` by default and observe `last-result.json` / `Get-LoopStatus.ps1` instead of relying on attached terminal output. Keep observing detached status until the requested wait/watch condition reaches a terminal or actionable state; use attached `loop.ps1` only as a short-lived/debugging exception.
8. If the loop exits with an actionable code, or detached status reports `actionable`, and no action is configured, handle the work, validate it, explicitly ack any stateful marker, then restart only if this is a watch-until-terminal loop.
9. If the loop exits `0`, or detached status reports a final success, continue with the requested success action or final report.

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
$manifest = .\scripts\Start-LoopDetached.ps1 `
  -Name "local-service-health" `
  -CheckCommand "Invoke-WebRequest -UseBasicParsing http://localhost:3000/health | Out-Null" `
  -IntervalSeconds 5 `
  -TimeoutSeconds 120 `
  -StableForSeconds 5 | ConvertFrom-Json

.\scripts\Get-LoopStatus.ps1 -RunDir $manifest.runDir
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

### Agent-reasoned peek, act, then ack

Use this pattern when the agent needs to inspect the event and take dynamic action, such as responding to PR review comments, fixing CI, or resolving merge conflicts. The check only reports that new work exists and preserves enough details for the agent.

```bash
scripts/loop.sh \
  --check "./check-work.sh --marker marker.json --mode peek --out event.json" \
  --retry-exit-codes 10 \
  --stop-exit-codes 31 \
  --interval 60 \
  --timeout 3600
```

When the loop exits `31`, or detached status reports `actionable` for that stop code, inspect `event.json`, complete the work, validate it, then explicitly acknowledge. Restart only if the loop is intended to keep watching:

```bash
./check-work.sh --marker marker.json --mode ack --event event.json
```

```powershell
$manifest = .\scripts\Start-LoopDetached.ps1 `
  -Name "peek-work" `
  -CheckCommand ".\check-work.ps1 -Marker marker.json -Mode Peek -Out event.json" `
  -RetryExitCode 10 `
  -StopExitCode 31 `
  -IntervalSeconds 60 `
  -TimeoutSeconds 3600 | ConvertFrom-Json

.\scripts\Get-LoopStatus.ps1 -RunDir $manifest.runDir
```

After handling succeeds:

```powershell
.\check-work.ps1 -Marker marker.json -Mode Ack -Event event.json
```

### Automation-only peek, action, then ack

Use `--ack` / `-AckCommand` when the action is a deterministic command that fully handles the work without agent reasoning. The check must still not advance the marker when it finds actionable work.

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
$manifest = .\scripts\Start-LoopDetached.ps1 `
  -Name "automation-work" `
  -CheckCommand ".\check-work.ps1 -Marker marker.json -Mode Peek" `
  -RetryExitCode 10 `
  -StopExitCode 31 `
  -ActionCommand ".\handle-work.ps1" `
  -AckCommand ".\check-work.ps1 -Marker marker.json -Mode Ack" `
  -IntervalSeconds 60 `
  -TimeoutSeconds 3600 | ConvertFrom-Json

.\scripts\Get-LoopStatus.ps1 -RunDir $manifest.runDir
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
$manifest = .\scripts\Start-LoopDetached.ps1 `
  -Name "pr-123-ready" `
  -CheckCommand ".\scripts\check-pr-ready.ps1 -Pr 123 -RequireReview" `
  -IntervalSeconds 300 `
  -TimeoutSeconds 21600 `
  -RetryExitCode 10 `
  -StopExitCode 11,20,21,22,23,24 `
  -ActionCommand "gh pr merge 123 --squash --delete-branch --match-head-commit (gh pr view 123 --json headRefOid --jq .headRefOid)" | ConvertFrom-Json

.\scripts\Get-LoopStatus.ps1 -RunDir $manifest.runDir
```

If the loop exits with `20` or `21`, or detached status reports `actionable` for those stop codes, inspect the failure, fix CI or conflicts, push, and restart the loop. If it exits `11`, update the branch and restart the loop. If it exits `0` or detached status reports final success, the action has run.

Use `last-result.json` as the source of truth for the latest attempt. `Get-LoopStatus.ps1` reports `starting`, `running`, `stalled` (process alive but heartbeat stale), `crashed` (process gone without a terminal event), `actionable`, or `final`.

### Attached PowerShell short-lived/debug exception

Use this only when you know the loop should finish quickly or you need live output while debugging. If it may run for a while, use detached mode instead.

```powershell
.\scripts\loop.ps1 `
  -CheckCommand "Test-Path .\package.json" `
  -IntervalSeconds 1 `
  -MaxTries 3
```

## More detail

Read `references/guide.md` for full runner behavior and `references/pr-polling.md` for the PR decision table and recipes.
