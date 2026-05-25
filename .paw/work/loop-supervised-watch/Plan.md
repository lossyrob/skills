# Plan

## Approach Summary

Implement the hardened observed-watch v1 design by strengthening the existing Windows detached loop flow instead of adding a supervisor process. The implementation keeps the current mental model: `Start-LoopDetached.ps1` launches one durable worker run, `Wait-LoopDetached.ps1` remains the attached/backgrounded Copilot CLI-observed waiter, and the run directory remains the durable source of truth.

The plan directly addresses the known reliability gaps:

- Missing or broken status helper should not hide durable final/actionable state.
- Long watch-until-terminal workflows should not end because an omitted default timeout expired.
- Actionable/final wakeups should include structured metadata that makes the wake reason explicit after the shell notification.
- Run directory cleanup should be an agent-visible obligation with a safe cleanup command and TODO guardrail.

## Work Items

- [x] **Harden waiter fallback and wake metadata**
  - Move missing `Get-LoopStatus.ps1` handling into the durable fallback path instead of exiting bare text code `3`.
  - Ensure helper missing, helper throws, helper empty output, and helper malformed output all produce structured JSON when durable state can be classified.
  - Add generic `lastWake` metadata to waiter output for actionable/final wakeups, preserving domain-provided reason/event, exit code, summary/stdout, attempt, timestamp, and event path where available.
  - Pin the additive `lastWake` contract for tests and consumers: `kind` (required string), `classification` (required string), `exitCode` (required integer), `loopStatus` (optional string), `status` (optional string), `event` (optional string), `summary` (optional string), `attempt` (optional integer), `detectedAt` (optional timestamp string), and `eventPath` (optional string).
  - Keep existing waiter exit-code behavior: configured actionable code for actionable, `0` for success, `124` for loop timeout, `125` for persistent stall, and infrastructure/error code when unclassifiable.

- [x] **Add explicit watch-until-terminal intent**
  - Add `-WatchUntilTerminal` to `Start-LoopDetached.ps1`.
  - When `-WatchUntilTerminal` is set and `-TimeoutSeconds` was not explicitly supplied, launch the worker with `TimeoutSeconds = 0`.
  - Record watch intent in `manifest.json` and `params.json` so status/waiter output can explain long-watch behavior.
  - Preserve explicitly supplied finite timeouts for bounded waits while making the configured timeout visible in metadata; explicit `-TimeoutSeconds` wins over the watch-until-terminal default and should have a regression test.

- [x] **Add safe loop cleanup tooling**
  - Add `Invoke-LoopCleanup.ps1` for `$HOME\.copilot\loop-runs\`.
  - Default to report/WhatIf behavior; require `-Apply` for deletion.
  - Skip live runs using PID plus process start-time validation.
  - Retain actionable, failed, crashed, stalled, infrastructure-failure, malformed, ambiguous, and locked runs by default.
  - Prune only eligible old final-success runs according to retention/count options.

- [x] **Update loop documentation and agent guardrails**
  - Update `skills/loop/SKILL.md` and `skills/loop/references/guide.md`.
  - Document `-WatchUntilTerminal`, attached/backgrounded waiter requirements, structured `lastWake`, and the cleanup command.
  - Add an agent cleanup TODO guardrail for long detached watches: create a cleanup TODO before or immediately after starting long watches and resolve it before final response or PR handoff.
  - Keep the design generic and leave PR-specific event semantics to PR lifecycle/check scripts.

- [x] **Validate and package**
  - Add or update PowerShell regression tests for waiter fallback, watch-until-terminal launch behavior, structured wake metadata, and cleanup safety.
  - Include a smoke test that confirms new waiter JSON fields are additive and do not remove existing status fields.
  - Run existing loop test scripts plus new tests.
  - Update plugin metadata version consistently if packaging changes require it.
  - Commit implementation changes with selective staging.

## Key Decisions

- V1 does not add a detached supervisor process, watch root, generation tree, or new observed-watch script family.
- The existing run directory remains the durable state boundary.
- Long watch robustness is achieved by explicit watch intent and unbounded worker timeout by default, not by automatic rollover generations.
- Cleanup is explicit agent-managed work, not a hidden worker/waiter side effect and not something left to user memory.
- `Invoke-LoopCleanup.ps1` should be conservative and reporting-first; destructive deletion requires `-Apply`.
- `lastWake` is generic and preserves domain-provided data; the loop skill does not encode PR lifecycle semantics.

## Open Questions

None.
