# Loop Runner Guide

The loop skill provides one Bash runner and a PowerShell runner with a detached launcher:

- `scripts/loop.sh` for Bash-compatible shells.
- `scripts/Start-LoopDetached.ps1` for default Windows PowerShell 5.1 and PowerShell 7+ worker use.
- `scripts/Wait-LoopDetached.ps1` as the attached quiet observer that wakes the agent when a detached worker needs attention.
- `scripts/loop.ps1` for the short-lived/debug PowerShell exception.

The runners repeatedly execute a check command until the command succeeds, the loop times out, the maximum attempt count is reached, or the check returns a configured stop exit code. In PowerShell, default to detached mode unless you know the loop will be short-lived or the user explicitly wants live terminal output.

## Core options

| Concept | Bash | PowerShell | Default |
|---|---|---|---|
| Check command | `--check CMD` | `-CheckCommand CMD` | required |
| Success action | `--action CMD` | `-ActionCommand CMD` | none |
| Acknowledgement | `--ack CMD` | `-AckCommand CMD` | none |
| Retry hook | `--on-retry CMD` | `-OnRetryCommand CMD` | none |
| Interval | `--interval N` | `-IntervalSeconds N` | `30` |
| Worker timeout | `--timeout N` | `-TimeoutSeconds N` | `3600` |
| Watch-until-terminal intent | n/a | `Start-LoopDetached.ps1 -WatchUntilTerminal` | off |
| Waiter timeout | n/a | `Wait-LoopDetached.ps1 -TimeoutSeconds N` / `-MaxAttachedSeconds N` | `0` (unbounded) |
| Max tries | `--max-tries N` | `-MaxTries N` | `0` (disabled) |
| Backoff | `--backoff-factor N` | `-BackoffFactor N` | `1` |
| Max interval | `--max-interval N` | `-MaxIntervalSeconds N` | `300` |
| Jitter | `--jitter-percent N` | `-JitterPercent N` | `0` |
| Stability window | `--stable-for N` | `-StableForSeconds N` | `0` |
| Invert result | `--invert` | `-Invert` | off |
| Retry codes | `--retry-exit-codes 1,10` | `-RetryExitCode 1,10` | all non-zero except stop codes |
| Stop codes | `--stop-exit-codes 20,21` | `-StopExitCode 20,21` | `126,127` |
| Singleton lock | `--lock-name NAME` | `-LockName NAME` | none |
| Attached log file (`loop.ps1`) | n/a | `-LogPath PATH` | none |
| Attached latest result file (`loop.ps1`) | n/a | `-LastResultPath PATH` | none |
| Attached heartbeat file (`loop.ps1`) | n/a | `-HeartbeatPath PATH` | none |
| Attached event directory (`loop.ps1`) | n/a | `-EventDir DIR` | none |
| Dry run | `--dry-run` | `-DryRun` | off |
| Quiet | `--quiet` | `-Quiet` | off |

`Start-LoopDetached.ps1` accepts the same check, action, timing, and exit-code options as `loop.ps1`, adds detached-run options such as `-Name`, `-RunDir`, and `-Force`, and manages log/state paths automatically inside the run directory. `Wait-LoopDetached.ps1` accepts a run directory and waits quietly for `Get-LoopStatus.ps1` to report a wakeup state.

Use `-WatchUntilTerminal` for long detached workflows where elapsed time should not end the logical watch. When this switch is set and `-TimeoutSeconds` is omitted, the detached worker uses `TimeoutSeconds = 0`. If `-TimeoutSeconds` is supplied explicitly, that value wins and the manifest records that the timeout was explicit.

## PowerShell runner choice

For PowerShell, use `Start-LoopDetached.ps1` by default. Attached `loop.ps1` sessions depend on the agent continuing to consume a live terminal stream; if a loop lives longer than expected, the process can still be running while the agent's view of output is stale or incomplete. Detached runs avoid that by redirecting stdout/stderr to files and exposing structured status through `last-result.json`, `heartbeat.json`, `events\`, and `Get-LoopStatus.ps1`.

Detached workers are session-bound background processes, not independent daemons. The launcher records the owner process in the run manifest; if that owner exits, the worker writes an `abandoned` terminal result and exits the next time it checks ownership. Start the worker and the quiet waiter from the same owner/orchestrator process so the worker has a live owner for the whole observed watch.

The worker checks owner liveness before and after each check/action/ack/on-retry command and during sleeps. It does not terminate a child command that is already running, so each command should enforce its own timeout when a hang is possible.

Do not say "I'll continue when it exits" for a detached worker unless `Wait-LoopDetached.ps1` is actually running in the host CLI task UI.

CLI task backgrounding of `Wait-LoopDetached.ps1` is still an observed watch because the waiter remains managed and can complete when the detached worker needs attention. Backgrounding here means the host CLI task UI for the in-flight waiter command; do not wrap `Wait-LoopDetached.ps1` in `Start-Job`, `Start-Process`, `&`, or another shell-side detacher.

Use attached `loop.ps1` only when you have positive evidence that the loop is short-lived, the user explicitly asked for live terminal output, or you are debugging the check command. If duration is uncertain, detached wins.

## Exit-code behavior

The default policy is:

1. `0` means success.
2. Non-zero means retry.
3. `126` and `127` stop immediately because they usually mean "not executable" or "command not found".
4. Timeout or max tries returns `124`.

`Wait-LoopDetached.ps1` maps detached status back to useful tool exit codes:

| Code | Meaning |
|---:|---|
| `0` | Detached worker reached final success. |
| configured stop code | Detached worker reached `actionable`; the waiter exits with the check's stop code when available. |
| `1` | Detached worker crashed, action result was missing after an actionable event, or terminal failure had no more specific code. |
| `3` | Detached worker reported a fatal not-found/not-executable check. |
| `122` | Opt-in waiter timeout expired before the worker reached a wakeup state; only emitted when `Wait-LoopDetached.ps1 -TimeoutSeconds` / `-MaxAttachedSeconds` is greater than `0`. |
| `124` | Detached worker timed out or hit max tries. |
| `125` | Waiter saw an abandoned owner or persistent stalled status. |

When a detached worker has `-ActionCommand`, the waiter does not wake on the initial actionable event while that worker is still alive. It waits for action/ack completion: action success exits `0`, action failure exits the action code, and ack failure exits the ack code.

The waiter has no timeout by default (`-TimeoutSeconds 0`; the legacy `-MaxAttachedSeconds` alias is still supported). If you explicitly pass a waiter timeout and the emitted JSON has `waiter.timedOut: true`, the detached worker may still be running; decide whether to continue waiting with a live owner or stop the workflow. If the user needs to continue chatting while the waiter is active, background the waiter task in the host CLI task UI; do not convert the workflow to detached-only status polling.

Use retry and stop lists for multi-state checks:

```bash
scripts/loop.sh \
  --check "./check-state.sh" \
  --retry-exit-codes 10 \
  --stop-exit-codes 20,21,22
```

In this example, `10` means "keep waiting", while `20`, `21`, and `22` return control to the agent.

If an action command is configured and the check exits with a stop code, the runner treats that stop code as actionable:

1. Run the action command.
2. If the action exits `0`, run the ack command if configured.
3. If action and ack both exit `0`, the loop exits `0`.
4. If action or ack fails, the loop exits with that failure code.

Without an action command, stop codes keep their original behavior: the loop exits with the check's code and returns control to the agent.

## Stateful checks: peek -> act -> ack

Check commands must be observational unless they fully handle the work themselves. A check that advances a cursor, marker, checkpoint, offset, queue lease, or "last seen" timestamp before the agent acts can lose work if the loop exits or the action fails.

There are two safe patterns:

| Pattern | Safe when | Example |
|---|---|---|
| Non-consuming check | The agent must reason and act dynamically afterward. | PR review feedback arrives, CI fails, merge conflict appears. |
| Consuming check | The script itself fully completes the work atomically before marking it done. | A cleanup script deletes expired temp files and records completion. |

For agent-reasoned workflows, do not hide the work inside the checker and do not advance the marker from the checker. The checker should only report that new work exists and preserve enough details for the agent to inspect.

Use this pattern for persisted state that requires agent reasoning:

1. **Peek/check** reads external state and compares it to a marker.
   - No new work: return the retry code, for example `10`.
   - New actionable work: write details to stdout or an artifact and return a stop/action code, for example `31`.
   - Do not advance the marker when returning an actionable code.
2. **Agent acts** outside the runner: inspect details, reason about the response, edit code, validate, push, reply, or otherwise complete the work.
3. **Ack** advances the marker only after the agent completes the response successfully.

Before starting an agent-reasoned stateful loop, decide whether it is single-shot or watch-until-terminal:

- **Single-shot**: handle one detected event, ack if needed, then continue with the next instruction or final response.
- **Watch-until-terminal**: handle each detected event, ack if needed, then restart the loop until the terminal condition is reached.

Use todos for agent-reasoned stateful loops when there may be substantial work between detection and acknowledgement. Track at least these steps: inspect the emitted event details, handle and validate the event, run the exact ack command, and either restart the loop or finish according to the chosen lifecycle. Simple stateless waits do not need this todo guardrail.

For long detached watch-until-terminal workflows, also create a cleanup todo such as `loop-cleanup:<watch-or-work-id>`. Resolve it before final response or PR handoff by running `Invoke-LoopCleanup.ps1` in report mode, inspecting the report, and applying deletion only for eligible final-success or abandoned runs. Record an intentional skip when ambiguous or diagnostically useful runs are retained.

Example:

```bash
scripts/loop.sh \
  --check "./check-work.sh --marker marker.json --mode peek --out event.json" \
  --retry-exit-codes 10 \
  --stop-exit-codes 31 \
  --interval 60 \
  --timeout 3600
```

When the loop exits with `31`, or detached status reports `actionable` for that stop code, the agent handles `event.json`. After successful handling, ack the marker:

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

After successful handling:

```powershell
.\check-work.ps1 -Marker marker.json -Mode Ack -Event event.json
```

Use `--ack` / `-AckCommand` only when the action is automation-only and fully handles the work:

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

## Timing

The runners enforce a wall-clock timeout. Bash uses `date +%s` for macOS/Linux portability. PowerShell uses `[System.Diagnostics.Stopwatch]`.

Backoff multiplies the current interval after each retry:

```bash
scripts/loop.sh --check "curl -fsS http://localhost:8080/health" \
  --interval 2 \
  --backoff-factor 2 \
  --max-interval 60 \
  --timeout 300
```

Jitter adds a random delay up to the requested percentage of the current interval. It is useful when multiple agents may poll the same service.

## Stability windows

Use `--stable-for` / `-StableForSeconds` when a condition may briefly become true before it is actually ready:

```bash
scripts/loop.sh --check "curl -fsS http://localhost:8080/health" \
  --stable-for 10 \
  --timeout 300
```

The runner checks once, waits for the stability window, then checks again. Success is reported only if both checks pass.

## Environment variables

Every check, action, ack, and on-retry command receives:

```text
LOOP_ATTEMPT
LOOP_ELAPSED_SECONDS
LOOP_REMAINING_SECONDS
```

Action, ack, and on-retry commands additionally receive the check result that triggered them:

```text
LOOP_CHECK_EXIT_CODE
```

Example:

```bash
scripts/loop.sh --check 'test "$LOOP_ATTEMPT" -ge 3' --interval 1 --timeout 10
```

## PowerShell durable state files

Detached PowerShell runs write deterministic state files after each attempt and are the recommended observation mechanism for agent workflows because they do not depend on Copilot consuming an attached PTY/stdout stream. The attached `loop.ps1` runner can also write the same files when explicitly passed state paths, but that should be reserved for short-lived/debug cases.

```powershell
$manifest = .\scripts\Start-LoopDetached.ps1 `
  -Name "stateful-work" `
  -CheckCommand ".\check-work.ps1 -Mode Peek" `
  -WatchUntilTerminal `
  -RetryExitCode 10 `
  -StopExitCode 31 `
  -IntervalSeconds 60 `
  -Quiet | ConvertFrom-Json

.\scripts\Wait-LoopDetached.ps1 -RunDir $manifest.runDir -PollIntervalSeconds 10
```

`last-result.json` is overwritten atomically after each check attempt. Its schema includes:

```json
{
  "schemaVersion": 1,
  "timestamp": "2026-05-19T06:34:05.195Z",
  "pid": 61392,
  "attempt": 1,
  "elapsedSeconds": 0,
  "remainingSeconds": 30,
  "checkExitCode": 10,
  "loopStatus": "retry",
  "status": "WAIT",
  "event": "retryable_exit",
  "stdout": "{...}",
  "stderr": "",
  "nextSleepSeconds": 60,
  "nextAttemptAfter": "2026-05-19T06:35:05.195Z",
  "terminal": false
}
```

If the check command prints a JSON object with `status` or `event`, those values are copied into the latest-result file. Treat those values as check-reported, untrusted labels: the runner's authoritative state is `loopStatus`, `checkExitCode`, and `terminal`. Terminal states (`success`, actionable stop codes, fatal errors, timeout/max-tries, action/ack failures, and crashes) also write immutable event files under `EventDir` so an agent can recover missed terminal output.

## Detached PowerShell loops

For PowerShell workflows, default to `Start-LoopDetached.ps1` over launching `loop.ps1` in an attached Copilot async terminal. Detached mode redirects stdout/stderr to log files and observes progress through state files:

```powershell
$manifest = .\scripts\Start-LoopDetached.ps1 `
  -Name "review-watch" `
  -CheckCommand ".\check-review.ps1 -Repo owner/repo -PullRequest 123" `
  -WatchUntilTerminal `
  -RetryExitCode 10 `
  -StopExitCode 31 `
  -IntervalSeconds 60 | ConvertFrom-Json
```

The run directory contains:

| File | Purpose |
|---|---|
| `manifest.json` | Worker PID/start time, owner PID/start time, command, and all important paths. |
| `params.json` | Full loop parameter set. Complex check/action strings are passed through this file, not through `Start-Process` command-line quoting. |
| `loop.pid` | Loop process ID. |
| `stdout.log` / `stderr.log` | Redirected terminal output. Pass `-Quiet` to `Start-LoopDetached.ps1` to keep these sparse. |
| `last-result.json` | Latest structured check result. |
| `heartbeat.json` | Latest heartbeat (`checking`, `sleeping`, `action`, etc.). |
| `events\*.json` | Immutable terminal/actionable events. |

When `-RunDir` is provided explicitly, `Start-LoopDetached.ps1` refuses to overwrite a directory whose manifest still points at a live loop process. Use `-Force` only after confirming the prior process is stopped or intentionally abandoning that run.

For an observed watch, attach the quiet waiter to the durable run:

```powershell
.\scripts\Wait-LoopDetached.ps1 -RunDir $manifest.runDir -PollIntervalSeconds 30
```

`Wait-LoopDetached.ps1` emits no progress output. It repeatedly calls `Get-LoopStatus.ps1`, emits one final status JSON object with a `waiter` metadata field and additive `lastWake` metadata for final/actionable/abandoned wakeups, then exits. Its default wakeup states are `final`, `actionable`, `crashed`, `abandoned`, and three consecutive `stalled` polls. A one-off `stalled` classification may be a long check attempt; requiring consecutive stalled polls reduces false wakeups while still surfacing a persistently hung worker. `waiter.timeoutSeconds: 0` means the waiter is unbounded; if you opt into a waiter timeout, that timeout does not stop the detached worker.

`Get-LoopStatus.ps1` checks worker and owner PID liveness, process start times, and heartbeat freshness. Start-time validation prevents a recycled PID from making an old run look alive. Heartbeat freshness uses `heartbeat.nextAttemptAfter` or `heartbeat.nextSleepSeconds` when present, then falls back to `2 * IntervalSeconds + GraceSeconds`.

The waiter is disposable only while the original owner process is alive. If the waiter is interrupted but the owner remains alive, run `Wait-LoopDetached.ps1` again with the same `RunDir`; durable state remains the source of truth. If the owner is gone, status reports `abandoned` and new sessions must start a fresh loop instead of adopting the stale worker.

When a waiting task blocks user interaction, use the CLI task background option on `Wait-LoopDetached.ps1`. The detached worker still owns durability, and the backgrounded waiter still owns the automatic wakeup.

An observed watch's maximum lifetime is normally bounded by the detached worker's own timeout. Use `Start-LoopDetached.ps1 -WatchUntilTerminal` to make that intent explicit and default the worker timeout to `0`, so the observed watch can run indefinitely until the worker reaches a wakeup classification.

| Classification | Meaning |
|---|---|
| `starting` | PID exists but no heartbeat has been written yet. |
| `running` | PID exists and heartbeat is fresh. |
| `stalled` | PID exists but heartbeat is past its expected freshness deadline; the check may be hung or unusually slow. |
| `actionable` | Latest immutable event is an actionable stop-code event. |
| `final` | Latest immutable event is terminal (success, timeout, fatal, etc.). |
| `abandoned` | The recorded owner process exited; the worker either wrote an abandoned event or status refused an owner-dead run. |
| `crashed` | PID is gone and no terminal event was written. |

Detached run directories are durable scratch state. They may contain command strings, stdout/stderr, and check-reported JSON, so do not put secrets in inline commands or check output. Keep run directories out of source control and use `Invoke-LoopCleanup.ps1` to report and prune old final-success or abandoned runs under `$HOME\.copilot\loop-runs\` when they are no longer useful.

## Cleanup

`Invoke-LoopCleanup.ps1` reports cleanup candidates by default and deletes only when `-Apply` is passed:

```powershell
.\scripts\Invoke-LoopCleanup.ps1 -RunRoot "$HOME\.copilot\loop-runs" -RetentionDays 7 -MaxCompletedRuns 50
.\scripts\Invoke-LoopCleanup.ps1 -RunRoot "$HOME\.copilot\loop-runs" -RetentionDays 7 -MaxCompletedRuns 50 -Apply
```

Cleanup skips live runs using PID plus process start-time validation. It retains actionable, failed, crashed, stalled, ambiguous, malformed, locked, and diagnostically useful runs by default. For agent-managed long watches, cleanup is a TODO-tracked wrap-up obligation, not a hidden worker/waiter side effect.

## Safety notes

- Prefer checked-in helper scripts or temporary scripts over complex inline commands.
- For PowerShell, default to `Start-LoopDetached.ps1`; use attached `loop.ps1` only for known short-lived or debugging loops.
- For detached PowerShell loops, run `Wait-LoopDetached.ps1` from the same owner/orchestrator process. Do not leave a detached worker as an independent background watch.
- Do not run untrusted command strings.
- Do not include secrets in check/action command strings or output; `params.json`, `stdout.log`, `stderr.log`, `last-result.json`, and `events\*.json` persist them until the run directory is deleted.
- Quote inline commands for the shell that will execute them. Prefer helper scripts when quoting becomes hard to audit.
- Do not advance persisted markers from a check that returns an actionable stop code.
- If follow-up requires agent reasoning, leave action/ack out of the loop runner; stop, let the agent act, then run an explicit ack command.
- For agent-reasoned stateful loops, use todos to track event handling, validation, the exact ack command, and whether to restart or finish afterward.
- Use consuming checks only for automation-only work that the script completes atomically.
- Always use a timeout or max tries for unattended loops.
- Use stop exit codes for actionable states so the agent can handle the work before deciding whether to restart or finish.
- Use `--lock-name` / `-LockName` if duplicate loops would race.
