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
2. For PowerShell, default to a detached worker plus `Wait-LoopDetached.ps1` when the agent should wake up and continue. Only call `loop.ps1` attached when you have positive evidence the loop is short-lived or the user explicitly wants live terminal output.
3. For detached PowerShell loops, explicitly choose observed watch or background handoff. A detached worker by itself does **not** generate Copilot/tool completion notifications. If the user needs to keep chatting while waiting, background the managed waiter task instead of skipping the waiter.
4. Run `--dry-run` first for non-trivial or destructive workflows.
5. Use `--timeout` or `--max-tries` unless the user explicitly asks for an unbounded loop.
6. Route actionable states through `--stop-exit-codes` so the agent can fix issues before deciding whether to restart or finish.
7. Decide whether the workflow is single-shot or watch-until-terminal before starting the loop.
8. Quote command strings for the shell that will execute them. For complex logic, write a temporary script and pass that script as the check command.
9. Stateful checks must be non-consuming: peek first, act next, and acknowledge only after the action succeeds.

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

Use the runner that matches the active shell. For PowerShell, detached mode is the default because attached terminal output can become stale from the agent's point of view if the loop lives longer than expected. Pair detached workers with the quiet waiter when the agent should sleep until the loop needs attention.

| Environment | Runner |
|---|---|
| macOS, Linux, Git Bash, WSL | `scripts/loop.sh` |
| Windows PowerShell 5.1 or PowerShell 7+ observed watch | `scripts/Start-LoopDetached.ps1` plus attached quiet `scripts/Wait-LoopDetached.ps1` |
| Windows PowerShell background handoff/status | `scripts/Start-LoopDetached.ps1` plus manual `scripts/Get-LoopStatus.ps1` |
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

Detached workers are durable background processes, not chat/tool-managed async jobs. A detached worker alone will not notify the agent when it reaches `final` or `actionable`. After starting one, choose exactly one orchestration mode:

| Mode | Use when | Agent obligation |
|---|---|---|
| Observed watch | The user asked you to wait, watch, continue when ready, or handle the next event. | Run attached quiet `Wait-LoopDetached.ps1` against the detached run directory, then background that waiter in the host CLI task UI by default when the user may need to keep chatting. The waiter exits when the durable state is `final`, `actionable`, `crashed`, or persistently `stalled`, which wakes the agent through normal tool completion. |
| Background handoff | The user explicitly wants the loop left running independently. | Tell the user it is independent, provide the run directory, and provide the exact status command. |

Do not say "I'll continue when it exits" or imply automatic continuation for a detached worker unless `Wait-LoopDetached.ps1` or another observer is actually running.

Backgrounding the waiter task in the host CLI task UI is still an observed watch: the waiter remains tool-managed and should complete when the detached worker needs attention. This differs from background handoff, where no waiter is running and the user must check status manually. Do not wrap `Wait-LoopDetached.ps1` in `Start-Job`, `Start-Process`, `&`, or another shell-side detacher; that removes it from the tool-completion channel and turns the workflow into background handoff.

Use this observed-watch pattern when the agent should wake up:

```powershell
$manifest = .\scripts\Start-LoopDetached.ps1 -Name "watch-name" -CheckCommand "<command>" | ConvertFrom-Json
.\scripts\Wait-LoopDetached.ps1 -RunDir $manifest.runDir -PollIntervalSeconds 10
```

`Wait-LoopDetached.ps1` is intentionally quiet while waiting. It emits one final status JSON object, with a `waiter` metadata field, then exits. By default it treats `final`, `actionable`, `crashed`, and three consecutive `stalled` polls as wakeup states and has no waiter-side freshness timeout (`-TimeoutSeconds 0`, also available through the legacy `-MaxAttachedSeconds` alias). Its exit code mirrors the underlying loop outcome where possible: `0` for success, configured actionable stop codes for `actionable`, `124` for loop timeout/max tries, and `125` for persistent stall. Exit `122` is only emitted when an explicit waiter timeout is passed with `-TimeoutSeconds` / `-MaxAttachedSeconds`; in that opt-in mode, inspect the emitted status JSON and decide whether to reattach or hand off. If the detached worker has `-ActionCommand`, the waiter stays attached while action/ack runs and exits `0` only after that automation succeeds. When interactivity matters during a long wait, the waiter command should be backgrounded by the host CLI task UI; do not replace it with detached-only status handoff unless the user asked to stop automatic wakeups.

The detached run directory is the source of truth; the attached waiter is only a transport. If `Get-LoopStatus.ps1` cannot be invoked (missing, throws, returns empty, returns malformed JSON, exits non-zero), the waiter falls back to reading `manifest.json`, `last-result.json`, and `events\*.json` directly from the run directory. When that durable read yields an `actionable` or `final` classification, the waiter exits through the normal path with the configured actionable code (or `0` for terminal success) and `waiter.exitReason = 'status_read_fallback'`; the emitted JSON also carries `waiterFallbackSource = 'durable_files'`, `waiterFallbackDurableSources` (`lastResult`, `latestEvent`, or both), and `waiterErrors` describing what the helper read failed with. This is the recovery path for missed re-review / approval / +1 events that the loop worker finalized but the helper-based status read could not surface. Exit `121` (`waiter_internal_error`) is reserved for the case where both the helper and the durable read fail to yield a usable classification; the waiter still emits JSON with a `lastResult` snapshot when one is on disk, and `waiterFallbackSource` is then one of `previous_status_read`, `durable_files_unclassified`, `last_result_on_disk`, or `stub_only`.

For an explicit background handoff, do not start the waiter. The handoff must include:

```text
Run directory: <run-dir>
Status command: .\scripts\Get-LoopStatus.ps1 -RunDir "<run-dir>"
```

The detached launcher writes a run directory containing `manifest.json`, `loop.pid`, `stdout.log`, `stderr.log`, `last-result.json`, `heartbeat.json`, and immutable event files under `events\`. `manifest.json` records both the PID and process start time so status checks can reject recycled PIDs. Use `-Quiet` to suppress loop chatter in redirected logs. Use `-Force` only when intentionally reusing an explicit `-RunDir` whose prior loop is known to be stopped.

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
| `121` | `Wait-LoopDetached.ps1` could neither read status via `Get-LoopStatus.ps1` nor recover an `actionable`/`final` classification from a direct read of the run directory. The waiter still emits JSON; inspect `waiterError`, `waiterErrors`, `waiterFallbackSource`, and any `lastResult` snapshot before deciding whether to reattach or hand off. When the helper read fails but the durable run directory does carry an actionable or final result, the waiter exits with the normal actionable/`0` code and `waiter.exitReason = 'status_read_fallback'` instead of `121`. |
| `122` | Opt-in waiter timeout before the detached worker reached a wakeup state; only emitted when `Wait-LoopDetached.ps1 -TimeoutSeconds` / `-MaxAttachedSeconds` is greater than `0`. |
| `124` | Timeout or max tries reached. |
| `125` | Detached waiter detected a persistent stalled state. |

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
7. Start the loop. For PowerShell, use `Start-LoopDetached.ps1` by default. If the agent should continue when the loop needs attention, immediately run attached quiet `Wait-LoopDetached.ps1` on the returned run directory. Use `Get-LoopStatus.ps1` for manual status checks or explicit background handoff.
8. If the loop exits with an actionable code, or detached status reports `actionable`, and no action is configured, handle the work, validate it, explicitly ack any stateful marker, then restart only if this is a watch-until-terminal loop.
9. If the loop exits `0`, or detached status reports a final success, continue with the requested success action or final report.
10. Before final response after starting a detached worker, confirm that the waiter completed, another observer is running, or you clearly handed off the run directory and exact status command.

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

.\scripts\Wait-LoopDetached.ps1 -RunDir $manifest.runDir -PollIntervalSeconds 5
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

.\scripts\Wait-LoopDetached.ps1 -RunDir $manifest.runDir -PollIntervalSeconds 10
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

.\scripts\Wait-LoopDetached.ps1 -RunDir $manifest.runDir -PollIntervalSeconds 10
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

.\scripts\Wait-LoopDetached.ps1 -RunDir $manifest.runDir -PollIntervalSeconds 30
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
