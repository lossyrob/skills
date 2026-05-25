# Loop Supervised Watch Design

Status: design draft  
Work ID: `loop-supervised-watch`  
Scope: `skills/loop` long-wait reliability for Windows detached loops, PAW PR/re-review sentry, and related documentation/tests.

## Problem

The current Windows loop model has two important pieces:

1. `Start-LoopDetached.ps1` starts a durable `loop.ps1` worker and writes a run directory.
2. `Wait-LoopDetached.ps1` remains tool-managed so Copilot CLI can wake the agent when the run becomes final, actionable, crashed, or persistently stalled.

That model works for many waits, but it treats one worker run as the unit of liveness. A long PR/re-review sentry can miss future events if the worker reaches a finite timeout and no active observer restarts it. The previous hourly waiter recycling was noisy, but it accidentally acted like a weak supervisory layer. Removing that noise exposed the deeper issue: long waits need a logical watch owner, not only one worker process plus one waiter process.

## Design Goals

- Preserve Copilot CLI automatic wakeup while keeping chat usable during long waits.
- Make the durable unit a logical watch, not an individual worker generation.
- Renew worker generations when a watch-until-terminal workflow is still waiting.
- Surface infrastructure failures as actionable wakeups instead of silently losing liveness.
- Add conservative cleanup and retention for run directories without deleting active or diagnostically useful state.
- Keep state file based operation inspectable, reattachable, and easy to debug.

## Non-goals

- Do not build a global daemon or background service.
- Do not rely on Copilot CLI internals beyond the documented shell/task behavior.
- Do not auto-ack stateful work. PR review, CI, conflicts, and re-review events remain agent-reasoned peek -> act -> ack flows.
- Do not delete run artifacts immediately on completion; they are the evidence needed for postmortems.

## Current Architecture

```text
Agent
  |
  | starts
  v
Start-LoopDetached.ps1 -----> loop.ps1 worker
  |                              |
  | writes run dir               | writes heartbeat, last-result, events
  v                              v
$HOME\.copilot\loop-runs\<run>  Get-LoopStatus.ps1
  ^                              |
  | reads                        |
Wait-LoopDetached.ps1 <----------
  |
  | attached/tool-managed completion
  v
Copilot CLI shell_completed notification
```

Important current properties:

- The run directory is the durable source of truth.
- The detached worker alone does not wake the agent.
- The waiter is intentionally quiet and disposable; it can be reattached to the same run directory.
- Copilot CLI backgrounding is appropriate for the waiter when it remains an attached/backgrounded shell task.
- Shell-side detaching the waiter is not equivalent; it turns observed watch into background handoff.

Known gaps:

- Missing `Get-LoopStatus.ps1` can still fail before durable fallback in some paths.
- A finite worker timeout is terminal even when the logical watch should continue.
- Run directories are durable scratch state with only manual cleanup guidance.

## Proposed Architecture

Introduce a supervised observed watch layer:

```text
Copilot CLI task runtime
  - foreground chat remains usable
  - attached/backgrounded waiter remains tool-managed
  - shell_completed wakes agent

Observed watch layer
  - Wait-LoopObserved.ps1 or enhanced Wait-LoopDetached.ps1
  - emits one final JSON wakeup
  - writes observer heartbeat/status
  - reports actionable/final/crashed/stalled/infrastructure failure

Durable watch supervisor layer
  - Start-LoopObserved.ps1 creates watch root + watch.json
  - starts worker generation N
  - renews generation N+1 on policy rollover
  - owns cleanup/retention
  - exposes watch-level status

Worker generation layer
  - Start-LoopDetached.ps1 starts loop.ps1 for one generation
  - each generation has its own run directory
  - loop.ps1 remains focused on check/action/ack/heartbeat/events
```

The key shift is semantic:

| Current concept | Proposed concept |
|---|---|
| One run is the watch. | One logical watch owns many possible runs. |
| Worker timeout ends the sentry. | Worker timeout can be a rollover boundary. |
| Run directory is the only durable handle. | Watch directory has `watch.json`; generation run dirs remain inspectable. |
| Cleanup is manual. | Supervisor applies conservative retention. |

## Process Model

Recommended process split:

1. **Detached supervisor process** owns logical liveness.
   - Starts worker generations.
   - Observes generation status.
   - Renews when policy says timeout is a rollover.
   - Writes `watch.json` heartbeat and cleanup status.
2. **Detached worker generation** performs repeated checks for one generation.
   - Existing `loop.ps1` contract mostly remains unchanged.
3. **Attached/backgrounded waiter** observes the watch and wakes the agent.
   - This is the process Copilot CLI should know about.
   - It should be backgrounded through the CLI task UI, not `Start-Job`, `Start-Process`, `&`, or `detach: true`.

If the waiter dies, automatic wakeup is lost, but the supervisor can keep the logical watch alive and preserve future events in durable state. If the supervisor dies, the waiter should detect stale supervisor heartbeat and wake with an infrastructure failure.

## Watch State

Proposed watch root:

```text
$HOME\.copilot\loop-watches\<watch-id>\
  watch.json
  supervisor.pid
  supervisor.log
  observer.json
  generations\
    0001\
      manifest.json
      params.json
      loop.pid
      stdout.log
      stderr.log
      last-result.json
      heartbeat.json
      events\
    0002\
      ...
```

`watch.json` should be the stable watch-level contract:

```json
{
  "schemaVersion": 1,
  "watchId": "pr-123-rereview",
  "name": "pr-123-rereview",
  "createdAt": "2026-05-25T20:00:00Z",
  "updatedAt": "2026-05-25T20:05:00Z",
  "state": "running",
  "policy": {
    "mode": "watch-until-terminal",
    "renewOnWorkerTimeout": true,
    "generationTimeoutSeconds": 43200,
    "maxGenerations": 0
  },
  "currentGeneration": {
    "number": 2,
    "runDir": "generations\\0002",
    "startedAt": "2026-05-25T20:05:00Z"
  },
  "lastWakeReason": null,
  "supervisor": {
    "pid": 1234,
    "processStartTime": "2026-05-25T20:00:00Z",
    "heartbeatAt": "2026-05-25T20:05:00Z"
  },
  "observer": {
    "heartbeatAt": "2026-05-25T20:05:00Z",
    "attached": true,
    "shellId": null
  },
  "cleanup": {
    "policy": "retain-current-and-failures",
    "retentionDays": 7,
    "maxCompletedGenerations": 2,
    "lastAttemptAt": null,
    "lastSuccessAt": null,
    "status": "not_run"
  }
}
```

## Watch States

| State | Meaning | Agent behavior |
|---|---|---|
| `starting` | Watch root exists; supervisor or first generation is starting. | Keep waiting unless startup deadline passes. |
| `running` | Supervisor and current worker generation are healthy. | Keep waiting. |
| `rolling_over` | Generation ended by rollover policy; next generation is being started. | Keep waiting unless rollover fails. |
| `actionable` | Current generation found an agent-reasoned event. | Wake agent, inspect event, act, ack, then restart/continue if needed. |
| `final` | Logical terminal condition reached, such as merged/closed/success. | Wake agent and finish. |
| `infrastructure_failure` | Supervisor cannot classify, renew, read status, or maintain liveness. | Wake agent; do not hide this as normal timeout. |
| `abandoned` | User explicitly handed off or stopped the watch. | No automatic wakeup expected. |

## Rollover Semantics

Generation terminal states are not always logical terminal states.

| Generation result | Watch policy says | Watch result |
|---|---|---|
| Success/final business condition | Terminal | `final` |
| Actionable stop code | Agent must act | `actionable` |
| Timeout while still waiting | Renew on timeout | Start next generation |
| Timeout while still waiting | No renewal | `final` with timeout |
| Crash/no terminal event | Not recoverable automatically | `infrastructure_failure` |

This avoids treating "12 hours elapsed while waiting for review" as "the PR sentry is done."

## Cleanup and Retention

Cleanup should be supervisor-owned and conservative.

Rules:

1. Never delete the current generation.
2. Never delete a generation whose PID and process start time still identify a live process.
3. Keep actionable, failed, crashed, and infrastructure-failure generations until acknowledged or manually pruned.
4. Keep the newest completed successful generations, default `maxCompletedGenerations = 2`.
5. Delete older successful rollover generations after `retentionDays`, default `7`.
6. In explicit background handoff mode, do not auto-clean unless cleanup was explicitly configured.
7. If deletion fails because files are locked or status is ambiguous, skip and record `cleanup.status = "pending"`.

Cleanup belongs at two levels:

| Cleanup level | Owner | Purpose |
|---|---|---|
| Watch-local generation cleanup | Supervisor | Prune old successful generations inside one logical watch. |
| Global orphan cleanup | Explicit command | Prune old standalone `$HOME\.copilot\loop-runs\` directories that are no longer active or useful. |

Suggested helper:

```powershell
.\scripts\Invoke-LoopCleanup.ps1 `
  -WatchRoot "$HOME\.copilot\loop-watches" `
  -RunRoot "$HOME\.copilot\loop-runs" `
  -RetentionDays 7 `
  -MaxCompletedGenerations 2 `
  -WhatIf
```

The helper should default to dry-run/WhatIf-like reporting for global cleanup. Destructive cleanup should require an explicit switch such as `-Apply`.

## Missing-helper Recovery

The missing `Get-LoopStatus.ps1` case should be treated as a recoverable status-read failure whenever durable files can classify the run or watch. The waiter should:

1. Resolve and validate the run/watch directory.
2. Attempt helper-based status.
3. If helper is missing or malformed, read durable files directly.
4. Emit JSON with a warning and `waiter.exitReason = "status_read_fallback"` when classification succeeds.
5. Emit `infrastructure_failure` JSON when no durable classification is possible.

Bare text exit code `3` should not be the first response for an existing run directory with useful durable state.

## Public Script Surface

Candidate scripts:

| Script | Purpose |
|---|---|
| `Start-LoopObserved.ps1` | Start a logical watch, supervisor, and first worker generation. |
| `Wait-LoopObserved.ps1` | Attached quiet waiter for a logical watch; emits one final JSON wakeup. |
| `Get-LoopWatchStatus.ps1` | Manual status for watch root and current generation. |
| `Invoke-LoopCleanup.ps1` | Conservative cleanup for watch generations and old orphan run dirs. |

Compatibility:

- Existing `Start-LoopDetached.ps1`, `Wait-LoopDetached.ps1`, and `Get-LoopStatus.ps1` remain supported.
- Simple waits can keep using detached worker + attached waiter.
- PAW PR/re-review sentry should move to supervised observed watch.

## Documentation Changes

Update loop skill docs to distinguish:

- **Observed watch**: attached/backgrounded waiter wakes the agent.
- **Background handoff**: no waiter; user receives run/status command.
- **Supervised observed watch**: logical watch with supervisor renewal and cleanup.

Document that Copilot CLI task backgrounding is appropriate for the waiter, while shell-side detaching the waiter is not.

## Test Plan

Add tests for:

- Missing `Get-LoopStatus.ps1` falls back to durable state and emits JSON.
- Worker timeout while still waiting starts generation N+1 under renew-on-timeout policy.
- Actionable event in any generation wakes the watcher and does not auto-ack.
- Supervisor stale heartbeat wakes waiter with `infrastructure_failure`.
- Cleanup skips active/current generation.
- Cleanup retains actionable/failure/crashed generations.
- Cleanup prunes old successful rollover generations after retention.
- Explicit background handoff does not start waiter and does not imply automatic wakeup.

## Open Questions

1. Should the watch root live under `$HOME\.copilot\loop-watches\` or should it reuse `$HOME\.copilot\loop-runs\` with a `watch.json` root?
2. Should `Start-LoopObserved.ps1` launch a separate detached supervisor process in the first implementation, or should the first version put renewal in the attached waiter and accept weaker liveness if the waiter dies?
3. What default retention is right for PAW PR sentry: 7 days, 14 days, or count-only retention?
4. Should global orphan cleanup ever run automatically, or only as an explicit user/agent command?
