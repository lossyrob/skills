---
name: paw-pr-lifecycle
description: Operate PAW implementer and reviewer GitHub PR lifecycle loops, including PR discovery, review response, post-approval sentry, re-review requests, and merge-readiness monitoring.
compatibility: PowerShell 7+ on any OS, the GitHub CLI authenticated against github.com, and the sibling `loop` skill (Start-LoopDetached.ps1 / Wait-LoopDetached.ps1 / Get-LoopStatus.ps1, ≥ 0.1.12).
---

# PAW PR Lifecycle

Use this skill when a PAW implementer or reviewer session must keep a GitHub PR moving after launch without relying on remembered chat history.

The lifecycle is intentionally mode-based. The launch prompt supplies variables and points at this skill; this skill carries the reusable loop commands, marker contracts, and terminal conditions.

This skill is opinionated for PAW workflow sessions: the marker strings (`🐾 PAW Implementer: Review Addressed`, `🐾 PAW Implementer: Re-review Requested`, `🐾 PAW Review: +1`) are part of the contract. Non-PAW adopters can fork the marker constants in `scripts\impl-review-response-check.ps1`, `scripts\review-addressed-check.ps1`, and the relevant reference docs.

## Inputs

The launch prompt should provide:

| Variable | Meaning |
|---|---|
| `<repo>` | GitHub `owner/repo`. Reviewer discovery needs this at launch; implementers may derive it from the PR they create before entering loop modes. |
| `<issue-number>` | Issue the implementation PR closes. |
| `<pr-number>` | PR number once known. |
| `<workstream-id>` | Optional task/tracker identifier used in the PR title (e.g., a workstream node ID, ticket key, or GitHub issue alias). |
| `<gh-user>` | GitHub login that the loop scripts must authenticate as. If only one account is authenticated via `gh auth login`, pass that login here; if multiple accounts are authenticated, the loop scripts pin to the named one via `gh auth token --user <login>`. |
| `<base-branch>` | Optional base branch when the issue gives branch guidance. |

## Shared setup

Resolve this skill's directory however your environment exposes it (e.g. the directory containing this `SKILL.md`). Examples below use `$SkillDir`; substitute your actual lookup. The sibling `loop` skill's script paths are discovered by the bundled `Get-LoopScriptPaths.ps1` helper, which checks the sibling skill directory, the standard plugin install paths, and a recursive `~/.copilot` fallback in order.

```powershell
# $SkillDir is the directory containing this SKILL.md.
$lifecycle   = $SkillDir
$loopScripts = Join-Path $lifecycle 'scripts'

$loopPaths    = & (Join-Path $loopScripts 'Get-LoopScriptPaths.ps1') | ConvertFrom-Json
$loopDetached = $loopPaths.detached
$loopWait     = $loopPaths.wait
$loopStatus   = $loopPaths.status

$ghUser = '<gh-user>'
```

Lifecycle loops must use the sibling `loop` skill's detached worker plus quiet waiter for observed watches. Do not run long-lived lifecycle sentries with `loop.ps1`, raw `Start-Process`, `Start-Job`, or a tool-managed async shell; those can open visible terminals or lose durable status. After starting a detached worker, run `Wait-LoopDetached.ps1` when this session is responsible for continuing. Use `Get-LoopStatus.ps1` only for manual inspection or explicit background handoff.

`Wait-LoopDetached.ps1` exits quietly when the lifecycle is actionable/final, and exits `122` after its one-hour attached-wait freshness bound while the detached worker may still be running. If the waiter returns JSON with `waiter.timedOut: true` and `classification` still `running` or `starting`, re-run the same waiter command against `$manifest.runDir` as a new tool call after observing the previous waiter JSON unless the user asked for background handoff.

Do not wrap `Wait-LoopDetached.ps1` in an outer PowerShell `while`/`do` loop or chain multiple waiter invocations inside one shell command. The one-hour waiter exit is intentional: it gives the agent a fresh tool-completion wakeup and a chance to reattach with a new waiter invocation. A waiter timeout is not a lifecycle event and is not permission to transition modes.

Before starting a new detached worker for the same PR, ensure the previous worker has reached an actionable/final state or is intentionally abandoned. If a previous worker may still be alive, inspect it with `$loopStatus`; do not start a duplicate worker for the same mode/PR. Only stop an abandoned worker by its exact manifest/status PID after verifying it belongs to that run.

Non-zero waiter exit codes are expected for actionable, timeout, stalled, and crashed states; the JSON body is authoritative. If the waiter returns empty or non-JSON output, treat that as a waiter internal failure: inspect the same `$manifest.runDir` with `$loopStatus` before restarting or replacing the worker.

## Role guides

| Role | Guide |
|---|---|
| Implementer | [references\implementer.md](references\implementer.md) |
| Reviewer | [references\reviewer.md](references\reviewer.md) |

## Marker contract

| Marker | Posted by | Meaning |
|---|---|---|
| `🐾 PAW Implementer: Review Addressed` | Implementer | A review or review-thread issue was handled and is ready for reviewer follow-up. Include the review ID or enough review details to disambiguate. |
| `🐾 PAW Implementer: Re-review Requested` | Implementer | The PR changed after approval, or a complex merge-conflict / builder-review repair deserves another human-quality review. Include reason, head SHA, and concise change summary. |
| `🐾 PAW Review: +1` | Reviewer | The reviewer has no further blocking feedback for the currently reviewed head. Prefer submitting this as the first line of a real PR review body. Treat the phrase as reserved; do not quote or negate it in non-approving feedback. A +1 review may include non-blocking notes (e.g., nits, optional suggestions, follow-up ideas); implementers must read the full review body before transitioning to PR Sentry and triage any notes per the implementer guide. |

## Terminal condition

For both implementer and reviewer sentries, **merge is the clean terminal condition**. A PR being approved or currently merge-ready is a steady state to monitor, not a reason to abandon the session.

For implementers, PR creation is not a terminal condition. After creating a PR, the session must enter Review Response mode before reporting completion: start the canonical implementer review-response loop, or handle an immediate checker event if one is already present. A pending Review Response lifecycle TODO after PR creation means the lifecycle handoff is incomplete.

## Script maintenance

If a loop exits with `script_or_github_api_error`, emits malformed JSON, or reveals a reusable detection bug, fix the canonical script under `scripts\` in this skill directory and submit a PR against the lossyrob-skills repository. Do not patch only a project-local fallback copy unless the canonical copy is unavailable.

