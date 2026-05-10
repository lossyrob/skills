# Loop Runner Guide

The loop skill provides two runners with the same behavior:

- `scripts/loop.sh` for Bash-compatible shells.
- `scripts/loop.ps1` for Windows PowerShell 5.1 and PowerShell 7+.

Both runners repeatedly execute a check command until the command succeeds, the loop times out, the maximum attempt count is reached, or the check returns a configured stop exit code.

## Core options

| Concept | Bash | PowerShell | Default |
|---|---|---|---|
| Check command | `--check CMD` | `-CheckCommand CMD` | required |
| Success action | `--action CMD` | `-ActionCommand CMD` | none |
| Acknowledgement | `--ack CMD` | `-AckCommand CMD` | none |
| Retry hook | `--on-retry CMD` | `-OnRetryCommand CMD` | none |
| Interval | `--interval N` | `-IntervalSeconds N` | `30` |
| Timeout | `--timeout N` | `-TimeoutSeconds N` | `3600` |
| Max tries | `--max-tries N` | `-MaxTries N` | `0` (disabled) |
| Backoff | `--backoff-factor N` | `-BackoffFactor N` | `1` |
| Max interval | `--max-interval N` | `-MaxIntervalSeconds N` | `300` |
| Jitter | `--jitter-percent N` | `-JitterPercent N` | `0` |
| Stability window | `--stable-for N` | `-StableForSeconds N` | `0` |
| Invert result | `--invert` | `-Invert` | off |
| Retry codes | `--retry-exit-codes 1,10` | `-RetryExitCode 1,10` | all non-zero except stop codes |
| Stop codes | `--stop-exit-codes 20,21` | `-StopExitCode 20,21` | `126,127` |
| Singleton lock | `--lock-name NAME` | `-LockName NAME` | none |
| Log file | n/a | `-LogPath PATH` | none |
| Dry run | `--dry-run` | `-DryRun` | off |
| Quiet | `--quiet` | `-Quiet` | off |

## Exit-code behavior

The default policy is:

1. `0` means success.
2. Non-zero means retry.
3. `126` and `127` stop immediately because they usually mean "not executable" or "command not found".
4. Timeout or max tries returns `124`.

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

Use this pattern for persisted state:

1. **Peek/check** reads external state and compares it to a marker.
   - No new work: return the retry code, for example `10`.
   - New actionable work: write details to stdout or an artifact and return a stop/action code, for example `31`.
   - Do not advance the marker when returning an actionable code.
2. **Act** handles the work.
3. **Ack** advances the marker only after the action exits `0`.

Example:

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

## Safety notes

- Prefer checked-in helper scripts or temporary scripts over complex inline commands.
- Do not run untrusted command strings.
- Quote inline commands for the shell that will execute them. Prefer helper scripts when quoting becomes hard to audit.
- Do not advance persisted markers from a check that returns an actionable stop code.
- Always use a timeout or max tries for unattended loops.
- Use stop exit codes for actionable states so the agent can fix and restart.
- Use `--lock-name` / `-LockName` if duplicate loops would race.
