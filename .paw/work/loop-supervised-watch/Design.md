# Hardened Observed Watch Design

Status: design draft  
Work ID: `loop-supervised-watch`  
Scope: `skills/loop` long-wait reliability for generic Windows detached-loop use cases. PR lifecycle management is the primary driving example, but domain-specific PR semantics belong outside the generic loop design.

## Decision

The first robust iteration should **not** introduce a separate detached supervisor process, watch root, generation tree, or new `Start-LoopObserved.ps1` / `Wait-LoopObserved.ps1` script family.

Instead, v1 hardens the existing observed-watch model:

```text
one detached worker + one attached/backgrounded waiter + one durable run directory
```

This is intentionally simpler than the earlier supervisor design. It addresses the known RCAs by strengthening the contracts around timeout intent, durable status fallback, actionable wakeup metadata, and cleanup, without adding another long-lived autonomous process that can fail.

## Problem

The current Windows loop model has two important pieces:

1. `Start-LoopDetached.ps1` starts a durable `loop.ps1` worker and writes a run directory.
2. `Wait-LoopDetached.ps1` remains tool-managed so Copilot CLI can wake the agent when the run becomes final, actionable, crashed, or persistently stalled.

That model works for many waits, but long autonomous agent workflows depend on it being boringly reliable. Known issues:

- A finite worker timeout can end a long logical watch before future events arrive.
- Some missing-helper paths in `Wait-LoopDetached.ps1` can fail before durable fallback.
- Actionable wakeups can look generic until the final waiter output is read.
- Run directories are durable scratch state with only manual cleanup guidance.
- Old waiter recycling reduced missed liveness but created noise and did not fix the underlying contracts.

## Reliability Model

The loop skill cannot guarantee progress across machine sleep, host process termination, broken credentials, network outages, or incorrect domain check scripts. It can guarantee stronger loop-layer behavior:

| Invariant | Required behavior |
|---|---|
| Durable state remains inspectable | The run directory is the source of truth for heartbeat, latest result, events, logs, and manifest. |
| Automatic wakeup is preserved when possible | The waiter remains an attached/backgrounded Copilot CLI shell task, not a shell-detached process. |
| Long watches do not end by accidental elapsed-time timeout | Watch-until-terminal workflows use unbounded worker timeout by default. |
| Status helper failures do not erase durable evidence | The waiter falls back to direct durable-file classification and emits JSON. |
| Domain events are not generic success | Waiter output carries structured `lastWake` metadata. |
| Unknown liveness is loud | Crashed, stalled, unreadable, or ambiguous state wakes as an infrastructure/status failure. |
| Scratch state is cleaned safely | Cleanup is explicit, PID/start-time safe, and conservative. |

## Architecture

```text
Copilot CLI runtime
  - foreground chat stays usable
  - task registry /tasks tracks attached shell tasks
  - attached/backgrounded shell runs Wait-LoopDetached.ps1
  - shell_completed notification wakes agent

Loop observer layer
  - Wait-LoopDetached.ps1 polls Get-LoopStatus.ps1
  - falls back to durable files if helper is missing or bad
  - emits one final JSON object with waiter + lastWake metadata
  - exits with success, domain stop code, timeout, stall, crash, or infrastructure failure

Durable worker layer
  - Start-LoopDetached.ps1 starts loop.ps1
  - loop.ps1 runs the check/action/ack loop
  - one run directory contains manifest, params, heartbeat, last-result, events, logs
  - watch-until-terminal mode uses TimeoutSeconds = 0 unless the caller explicitly opts into a finite timeout

Cleanup layer
  - Invoke-LoopCleanup.ps1 reports old runs by default
  - destructive cleanup requires explicit -Apply
  - active and diagnostically useful runs are retained
```

## Copilot CLI Integration

Copilot CLI has two different background concepts that must remain distinct:

| Mechanism | Meaning for this design |
|---|---|
| CLI task backgrounding / promoted sync shell | Correct for `Wait-LoopDetached.ps1`. The shell remains attached to Copilot's task runtime and can trigger `shell_completed`. |
| `mode: async` attached shell | Also correct for the waiter when the agent starts it that way. |
| `detach: true`, `Start-Process`, `Start-Job`, or `&` | Not correct for the waiter. These remove the waiter from the tool-completion channel and turn the workflow into background handoff. |
| `Start-LoopDetached.ps1` worker | Correctly detached from Copilot CLI. It owns durability, not notification. |

The worker and waiter have different jobs:

- The **worker** is durable and can survive normal agent idleness.
- The **waiter** is observed and wakes the agent.

If the waiter is interrupted, the worker can still be inspected and a new waiter can reattach to the same run directory. If the worker dies, the waiter should classify this as crashed/stalled/infrastructure failure and wake the agent.

## V1 Scope

### 1. Fix missing-helper durable fallback

`Wait-LoopDetached.ps1` should not exit bare text code `3` simply because sibling `Get-LoopStatus.ps1` is unavailable. It should:

1. Resolve and validate the run directory.
2. Attempt helper-based status when the helper exists.
3. If the helper is missing, throws, emits malformed output, or cannot classify, read durable files directly.
4. Emit structured JSON with `waiter.exitReason = "status_read_fallback"` when durable classification succeeds.
5. Emit structured infrastructure/status failure JSON when durable classification is impossible.

### 2. Make watch-until-terminal timeout intent explicit

The simplest robust answer to worker-timeout liveness loss is to avoid finite logical timeouts for watch-until-terminal workflows.

Add a generic intent marker such as:

```powershell
.\scripts\Start-LoopDetached.ps1 `
  -Name "long-watch" `
  -WatchUntilTerminal `
  -CheckCommand "<command>" `
  -IntervalSeconds 300 `
  -RetryExitCode 10 `
  -StopExitCode 20,21,22
```

Proposed behavior:

- `-WatchUntilTerminal` records `watchMode = "watch-until-terminal"` in `manifest.json`.
- If `-TimeoutSeconds` was not explicitly supplied, `Start-LoopDetached.ps1` passes `TimeoutSeconds = 0`.
- If `-TimeoutSeconds` is explicitly supplied, keep it but preserve the watch intent in the manifest so the waiter output can explain that a logical watch ended due to a configured finite timeout.
- Existing finite timeout behavior remains available for bounded waits.

This avoids adding a supervisor process and makes the safe long-watch mode explicit in command examples and skill guidance.

### 3. Add structured `lastWake` metadata

The loop framework should preserve the domain-provided reason and exit code without hard-coding domain semantics.

Waiter output should include a generic shape:

```json
{
  "state": "actionable",
  "runDir": "C:\\Users\\...\\.copilot\\loop-runs\\long-watch-...",
  "lastWake": {
    "kind": "actionable",
    "reason": "domain_event_requires_agent",
    "exitCode": 31,
    "summary": "The check detected work that requires agent reasoning",
    "attempt": 136,
    "detectedAt": "2026-05-25T19:58:31Z",
    "eventPath": "events\\20260525T195831Z-actionable.json"
  },
  "waiter": {
    "exitReason": "wakeup_state",
    "statusSource": "helper"
  }
}
```

For the generic loop skill, `actionable` means "wake the agent and require inspection," not "the watch completed successfully." Domain skills decide their own stop codes and reason names.

### 4. Add explicit safe cleanup

Add one cleanup script rather than embedding cleanup in a supervisor:

```powershell
.\scripts\Invoke-LoopCleanup.ps1 `
  -RunRoot "$HOME\.copilot\loop-runs" `
  -RetentionDays 7 `
  -MaxCompletedRuns 50 `
  -WhatIf
```

Destructive cleanup requires `-Apply`.

Cleanup should be an **agent obligation**, not a user-maintenance hope. The loop skill should instruct agents to create and complete an explicit cleanup TODO whenever they start a long watch or complete a workflow that used detached loop runs. The TODO keeps cleanup visible across long waits and prevents the agent from skipping directly from "watch finished" to final response.

Recommended TODO shape:

```text
loop-cleanup:<watch-or-work-id>
Title: Cleaning old loop run directories
Description: Run Invoke-LoopCleanup.ps1 with -WhatIf, inspect the report, then run -Apply if only eligible final-success runs would be deleted. Do not delete live, actionable, failed, crashed, stalled, infrastructure-failure, ambiguous, or locked runs.
```

The cleanup TODO should be considered done only after one of these outcomes:

- Cleanup ran with `-Apply` and reported only safe deletions/skips.
- `-WhatIf` found no eligible runs to delete.
- Cleanup found ambiguous or diagnostically useful runs, and the agent recorded that cleanup was intentionally skipped.

Cleanup rules:

1. Never delete a run whose PID and process start time still identify a live process.
2. Retain actionable, failed, crashed, stalled, and infrastructure-failure runs by default.
3. Retain recent final-success runs for postmortem/debugging.
4. Delete old final-success runs only after retention policy allows it.
5. Skip ambiguous, malformed, or locked runs and report them.
6. Never run automatic global cleanup as a side effect of waiting.
7. For agent-managed workflows, create the cleanup TODO before or immediately after starting the long watch, and resolve it before final response or PR handoff.

### 5. Update docs and examples

Docs should make the runner choice explicit:

| Use case | Recommended pattern |
|---|---|
| Short bounded retry | Existing `loop.ps1` or detached run with finite timeout. |
| Long watch where agent should continue | `Start-LoopDetached.ps1 -WatchUntilTerminal` + attached/backgrounded `Wait-LoopDetached.ps1`. |
| User wants independent handoff | Start detached worker only; provide run dir and status command; do not imply automatic wakeup. |
| Cleanup old scratch state | `Invoke-LoopCleanup.ps1 -WhatIf`, then `-Apply` after inspection. |

Docs should also add an agent guardrail: for long detached watches, create todos for event handling, ack/restart, and cleanup. Cleanup is not part of the polling loop itself; it is a required wrap-up task for the agent-managed workflow.

## Deferred Scope

Defer these until a concrete failure remains after v1:

- Separate detached supervisor process.
- `loop-watches\<watch-id>\generations\NNNN\` directory tree.
- `watch.json` as a second durable contract.
- `Start-LoopObserved.ps1`, `Wait-LoopObserved.ps1`, and `Get-LoopWatchStatus.ps1`.
- Automatic global orphan cleanup.
- Worker self-renewal / generations on timeout.

The design deliberately starts without these because they introduce another liveness owner, another heartbeat, another state hierarchy, and another source of false infrastructure failures.

## Failure Handling Matrix

| Failure | V1 behavior |
|---|---|
| Helper missing | Waiter reads durable files directly and emits JSON. |
| Durable files show actionable/final | Waiter wakes using durable fallback. |
| Durable files are malformed or insufficient | Waiter emits infrastructure/status failure JSON. |
| Worker reaches finite timeout in bounded mode | Waiter wakes with timeout/final state. |
| Worker reaches finite timeout in explicit watch mode | Waiter wakes with clear metadata that the watch ended due to configured timeout. |
| Worker process disappears without terminal event | Waiter wakes as crashed/infrastructure failure. |
| Heartbeat goes stale repeatedly | Waiter wakes as stalled. |
| Waiter is interrupted | User/agent can reattach with the same run directory. |
| Copilot CLI session exits | Worker may continue, but automatic wakeup is lost; status remains recoverable from run directory. |
| Old run dirs accumulate | Explicit cleanup reports and safely prunes eligible runs. |
| Agent might skip cleanup | Long-watch guidance requires a cleanup TODO and final check before response/handoff. |

## Test Plan

### V1 tests

- Missing `Get-LoopStatus.ps1` falls back to durable state and emits JSON.
- Helper malformed output falls back to durable state and emits JSON.
- No classifiable durable state emits structured infrastructure/status failure.
- `-WatchUntilTerminal` without explicit timeout records watch intent and starts worker with `TimeoutSeconds = 0`.
- Explicit timeout with `-WatchUntilTerminal` is preserved and surfaced clearly in final waiter output.
- Actionable event emits `lastWake.kind`, `lastWake.reason`, `lastWake.exitCode`, `lastWake.summary`, and `lastWake.eventPath`.
- Cleanup `-WhatIf` reports eligible runs without deleting.
- Cleanup `-Apply` skips live runs using PID + process start time.
- Cleanup retains actionable/failure/crashed/stalled runs by default.
- Cleanup prunes only eligible old final-success runs.
- Long-watch docs require an explicit cleanup TODO before final response/handoff.

### V2 tests if supervisor is later needed

- Supervisor heartbeat stale detection.
- Generation rollover rate limiting.
- Watch/run state consistency.
- Supervisor cleanup of older generations.

## Open Questions

1. Should the long-watch intent switch be named `-WatchUntilTerminal`, `-LongWatch`, or something else?
2. Should `-WatchUntilTerminal` reject explicit finite `-TimeoutSeconds`, or allow it with clear final metadata?
3. What default cleanup retention is right for generic final-success runs: 7 days, 14 days, count-only, or both?
4. Should `Invoke-LoopCleanup.ps1` live in v1, or should v1 only document a cleanup command pattern first?
