#!/usr/bin/env bash
set -euo pipefail

PROGRAM_NAME="$(basename "$0")"

CHECK_COMMAND=""
ACTION_COMMAND=""
ACK_COMMAND=""
ON_RETRY_COMMAND=""
INTERVAL_SECONDS=30
MAX_INTERVAL_SECONDS=300
TIMEOUT_SECONDS=3600
MAX_TRIES=0
BACKOFF_FACTOR=1
JITTER_PERCENT=0
STABLE_FOR_SECONDS=0
STOP_EXIT_CODES="126,127"
RETRY_EXIT_CODES=""
LOCK_NAME=""
INVERT=0
QUIET=0
DRY_RUN=0

SLEEP_PID=""
LOCK_DIR=""

EX_SUCCESS=0
EX_GENERAL=1
EX_BADARGS=2
EX_NOCMD=3
EX_TIMEOUT=124

usage() {
  cat <<'EOF'
Usage:
  loop.sh --check CMD [options]

Runs CMD until it succeeds, times out, reaches max tries, or returns a stop
exit code. CMD is evaluated by bash -c in a child shell.

Required:
  --check CMD                 Condition command. Exit 0 means ready.

Options:
  --action CMD                Run CMD once after the condition succeeds.
  --ack CMD                   Run CMD only after --action succeeds.
  --on-retry CMD              Run CMD after an unsuccessful retryable attempt.
  --interval SECONDS          Delay between attempts. Default: 30.
  --timeout SECONDS           Wall-clock timeout. 0 disables. Default: 3600.
  --max-tries N               Stop after N attempts. 0 disables. Default: 0.
  --backoff-factor N          Integer multiplier after each retry. Default: 1.
  --max-interval SECONDS      Maximum backoff interval. Default: 300.
  --jitter-percent N          Add random jitter up to N percent. Default: 0.
  --stable-for SECONDS        Re-check after condition stays true this long.
  --invert                    Succeed when CMD exits non-zero.
  --retry-exit-codes LIST     Only these non-zero codes are retryable.
  --stop-exit-codes LIST      Stop immediately for these codes. Default: 126,127.
  --lock-name NAME            Prevent concurrent loops with the same lock name.
  --quiet                     Suppress progress logs.
  --dry-run                   Print the plan without executing commands.
  --help                      Show this help.

Exit codes:
  0     Condition satisfied and optional action succeeded.
  1     General failure or stopped on a non-retryable condition code.
  2     Invalid arguments.
  3     Command not found or not executable.
  124   Timeout or max tries reached.

Loop environment available to commands:
  LOOP_ATTEMPT
  LOOP_ELAPSED_SECONDS
  LOOP_REMAINING_SECONDS
  LOOP_CHECK_EXIT_CODE
EOF
}

log() {
  if [ "$QUIET" -eq 0 ]; then
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
  fi
}

die() {
  printf '%s: %s\n' "$PROGRAM_NAME" "$*" >&2
  exit "$EX_BADARGS"
}

is_nonnegative_integer() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

require_nonnegative_integer() {
  local name="$1"
  local value="$2"
  if ! is_nonnegative_integer "$value"; then
    die "$name must be a non-negative integer: $value"
  fi
}

require_positive_integer() {
  local name="$1"
  local value="$2"
  require_nonnegative_integer "$name" "$value"
  if [ "$value" -le 0 ]; then
    die "$name must be greater than zero: $value"
  fi
}

code_in_list() {
  local code="$1"
  local list="${2:-}"
  [ -n "$list" ] || return 1
  case ",$list," in
    *,"$code",*) return 0 ;;
    *) return 1 ;;
  esac
}

run_command() {
  local command_text="$1"
  bash -c "$command_text"
}

run_action_and_ack() {
  local check_exit="$1"
  if [ -z "$ACTION_COMMAND" ]; then
    return 0
  fi

  export LOOP_CHECK_EXIT_CODE="$check_exit"

  log "running action"
  local action_exit=0
  run_command "$ACTION_COMMAND" || action_exit=$?
  if [ "$action_exit" -ne 0 ]; then
    printf '%s: action command failed with exit %s\n' "$PROGRAM_NAME" "$action_exit" >&2
    exit "$action_exit"
  fi

  if [ -n "$ACK_COMMAND" ]; then
    log "action succeeded; running ack"
    local ack_exit=0
    run_command "$ACK_COMMAND" || ack_exit=$?
    if [ "$ack_exit" -ne 0 ]; then
      printf '%s: ack command failed with exit %s\n' "$PROGRAM_NAME" "$ack_exit" >&2
      exit "$ack_exit"
    fi
  fi
}

cleanup() {
  local code=$?
  trap - EXIT INT TERM
  if [ -n "${SLEEP_PID:-}" ]; then
    kill "$SLEEP_PID" 2>/dev/null || true
    wait "$SLEEP_PID" 2>/dev/null || true
  fi
  if [ -n "${LOCK_DIR:-}" ] && [ -d "$LOCK_DIR" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  exit "$code"
}

interruptible_sleep() {
  local seconds="$1"
  if [ "$seconds" -le 0 ]; then
    return 0
  fi
  sleep "$seconds" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" || true
  SLEEP_PID=""
}

sanitize_lock_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

acquire_lock() {
  if [ -z "$LOCK_NAME" ]; then
    return 0
  fi
  local safe_name
  safe_name="$(sanitize_lock_name "$LOCK_NAME")"
  LOCK_DIR="${TMPDIR:-/tmp}/copilot-loop-${safe_name}.lock"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s: another loop is already running for lock %s (%s)\n' "$PROGRAM_NAME" "$LOCK_NAME" "$LOCK_DIR" >&2
    exit "$EX_GENERAL"
  fi
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check)
        [ "$#" -ge 2 ] || die "--check requires a command"
        CHECK_COMMAND="$2"
        shift 2
        ;;
      --action)
        [ "$#" -ge 2 ] || die "--action requires a command"
        ACTION_COMMAND="$2"
        shift 2
        ;;
      --ack)
        [ "$#" -ge 2 ] || die "--ack requires a command"
        ACK_COMMAND="$2"
        shift 2
        ;;
      --on-retry)
        [ "$#" -ge 2 ] || die "--on-retry requires a command"
        ON_RETRY_COMMAND="$2"
        shift 2
        ;;
      --interval)
        [ "$#" -ge 2 ] || die "--interval requires seconds"
        INTERVAL_SECONDS="$2"
        shift 2
        ;;
      --timeout)
        [ "$#" -ge 2 ] || die "--timeout requires seconds"
        TIMEOUT_SECONDS="$2"
        shift 2
        ;;
      --max-tries)
        [ "$#" -ge 2 ] || die "--max-tries requires a count"
        MAX_TRIES="$2"
        shift 2
        ;;
      --backoff-factor)
        [ "$#" -ge 2 ] || die "--backoff-factor requires a multiplier"
        BACKOFF_FACTOR="$2"
        shift 2
        ;;
      --max-interval)
        [ "$#" -ge 2 ] || die "--max-interval requires seconds"
        MAX_INTERVAL_SECONDS="$2"
        shift 2
        ;;
      --jitter-percent)
        [ "$#" -ge 2 ] || die "--jitter-percent requires a percent"
        JITTER_PERCENT="$2"
        shift 2
        ;;
      --stable-for)
        [ "$#" -ge 2 ] || die "--stable-for requires seconds"
        STABLE_FOR_SECONDS="$2"
        shift 2
        ;;
      --retry-exit-codes)
        [ "$#" -ge 2 ] || die "--retry-exit-codes requires a comma-separated list"
        RETRY_EXIT_CODES="$2"
        shift 2
        ;;
      --stop-exit-codes)
        [ "$#" -ge 2 ] || die "--stop-exit-codes requires a comma-separated list"
        STOP_EXIT_CODES="$2"
        shift 2
        ;;
      --lock-name)
        [ "$#" -ge 2 ] || die "--lock-name requires a name"
        LOCK_NAME="$2"
        shift 2
        ;;
      --invert)
        INVERT=1
        shift
        ;;
      --quiet)
        QUIET=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done

  [ -n "$CHECK_COMMAND" ] || die "--check is required"
  if [ -n "$ACK_COMMAND" ] && [ -z "$ACTION_COMMAND" ]; then
    die "--ack requires --action"
  fi
  require_positive_integer "--interval" "$INTERVAL_SECONDS"
  require_nonnegative_integer "--timeout" "$TIMEOUT_SECONDS"
  require_nonnegative_integer "--max-tries" "$MAX_TRIES"
  require_positive_integer "--backoff-factor" "$BACKOFF_FACTOR"
  require_positive_integer "--max-interval" "$MAX_INTERVAL_SECONDS"
  require_nonnegative_integer "--jitter-percent" "$JITTER_PERCENT"
  require_nonnegative_integer "--stable-for" "$STABLE_FOR_SECONDS"
}

calculate_sleep() {
  local current_interval="$1"
  local remaining="$2"
  local sleep_seconds="$current_interval"
  if [ "$JITTER_PERCENT" -gt 0 ]; then
    local jitter_max=$(( current_interval * JITTER_PERCENT / 100 ))
    if [ "$jitter_max" -gt 0 ]; then
      sleep_seconds=$(( sleep_seconds + RANDOM % (jitter_max + 1) ))
    fi
  fi
  if [ "$TIMEOUT_SECONDS" -gt 0 ] && [ "$remaining" -gt 0 ] && [ "$sleep_seconds" -gt "$remaining" ]; then
    sleep_seconds="$remaining"
  fi
  printf '%s\n' "$sleep_seconds"
}

condition_succeeded() {
  local exit_code="$1"
  if [ "$INVERT" -eq 0 ]; then
    [ "$exit_code" -eq 0 ]
  else
    [ "$exit_code" -ne 0 ]
  fi
}

is_retryable_failure() {
  local exit_code="$1"
  if code_in_list "$exit_code" "$STOP_EXIT_CODES"; then
    return 1
  fi
  if [ -n "$RETRY_EXIT_CODES" ]; then
    code_in_list "$exit_code" "$RETRY_EXIT_CODES"
    return
  fi
  return 0
}

main() {
  parse_args "$@"
  trap cleanup EXIT INT TERM
  acquire_lock

  if [ "$DRY_RUN" -eq 1 ]; then
    cat <<EOF
check=$CHECK_COMMAND
action=$ACTION_COMMAND
ack=$ACK_COMMAND
on_retry=$ON_RETRY_COMMAND
interval_seconds=$INTERVAL_SECONDS
timeout_seconds=$TIMEOUT_SECONDS
max_tries=$MAX_TRIES
backoff_factor=$BACKOFF_FACTOR
max_interval_seconds=$MAX_INTERVAL_SECONDS
jitter_percent=$JITTER_PERCENT
stable_for_seconds=$STABLE_FOR_SECONDS
invert=$INVERT
retry_exit_codes=$RETRY_EXIT_CODES
stop_exit_codes=$STOP_EXIT_CODES
lock_name=$LOCK_NAME
EOF
    exit "$EX_SUCCESS"
  fi

  local start_time deadline attempt current_interval
  start_time="$(date +%s)"
  if [ "$TIMEOUT_SECONDS" -gt 0 ]; then
    deadline=$(( start_time + TIMEOUT_SECONDS ))
  else
    deadline=0
  fi
  attempt=0
  current_interval="$INTERVAL_SECONDS"

  while :; do
    attempt=$(( attempt + 1 ))
    local now elapsed remaining
    now="$(date +%s)"
    elapsed=$(( now - start_time ))
    if [ "$deadline" -gt 0 ]; then
      remaining=$(( deadline - now ))
      [ "$remaining" -lt 0 ] && remaining=0
    else
      remaining=0
    fi

    unset LOOP_CHECK_EXIT_CODE 2>/dev/null || true
    export LOOP_ATTEMPT="$attempt"
    export LOOP_ELAPSED_SECONDS="$elapsed"
    export LOOP_REMAINING_SECONDS="$remaining"

    log "attempt ${attempt}: running check"
    local check_exit=0
    run_command "$CHECK_COMMAND" || check_exit=$?

    if condition_succeeded "$check_exit"; then
      if [ "$STABLE_FOR_SECONDS" -gt 0 ]; then
        log "condition met; waiting ${STABLE_FOR_SECONDS}s stability window"
        interruptible_sleep "$STABLE_FOR_SECONDS"
        local stable_exit=0
        unset LOOP_CHECK_EXIT_CODE 2>/dev/null || true
        run_command "$CHECK_COMMAND" || stable_exit=$?
        if ! condition_succeeded "$stable_exit"; then
          log "condition did not remain stable; continuing"
          check_exit="$stable_exit"
        else
          run_action_and_ack "$check_exit"
          exit "$EX_SUCCESS"
        fi
      else
        run_action_and_ack "$check_exit"
        exit "$EX_SUCCESS"
      fi
    fi

    if ! is_retryable_failure "$check_exit"; then
      if [ "$check_exit" -eq 126 ] || [ "$check_exit" -eq 127 ]; then
        printf '%s: check command failed with fatal exit %s\n' "$PROGRAM_NAME" "$check_exit" >&2
        exit "$EX_NOCMD"
      fi
      if [ -n "$ACTION_COMMAND" ] && code_in_list "$check_exit" "$STOP_EXIT_CODES"; then
        log "check returned actionable exit ${check_exit}"
        run_action_and_ack "$check_exit"
        exit "$EX_SUCCESS"
      fi
      printf '%s: check stopped with non-retryable exit %s\n' "$PROGRAM_NAME" "$check_exit" >&2
      exit "$check_exit"
    fi

    now="$(date +%s)"
    elapsed=$(( now - start_time ))
    if [ "$TIMEOUT_SECONDS" -gt 0 ] && [ "$now" -ge "$deadline" ]; then
      printf '%s: timed out after %ss (%s attempt(s))\n' "$PROGRAM_NAME" "$elapsed" "$attempt" >&2
      exit "$EX_TIMEOUT"
    fi
    if [ "$MAX_TRIES" -gt 0 ] && [ "$attempt" -ge "$MAX_TRIES" ]; then
      printf '%s: max tries reached after %s attempt(s)\n' "$PROGRAM_NAME" "$attempt" >&2
      exit "$EX_TIMEOUT"
    fi

    if [ -n "$ON_RETRY_COMMAND" ]; then
      export LOOP_CHECK_EXIT_CODE="$check_exit"
      log "running on-retry hook"
      run_command "$ON_RETRY_COMMAND" || {
        local retry_exit=$?
        printf '%s: on-retry command failed with exit %s\n' "$PROGRAM_NAME" "$retry_exit" >&2
        exit "$EX_GENERAL"
      }
    fi

    if [ "$deadline" -gt 0 ]; then
      remaining=$(( deadline - $(date +%s) ))
      [ "$remaining" -lt 0 ] && remaining=0
    else
      remaining=0
    fi
    local sleep_seconds
    sleep_seconds="$(calculate_sleep "$current_interval" "$remaining")"
    log "check exited ${check_exit}; sleeping ${sleep_seconds}s"
    interruptible_sleep "$sleep_seconds"

    if [ "$BACKOFF_FACTOR" -gt 1 ]; then
      current_interval=$(( current_interval * BACKOFF_FACTOR ))
      if [ "$current_interval" -gt "$MAX_INTERVAL_SECONDS" ]; then
        current_interval="$MAX_INTERVAL_SECONDS"
      fi
    fi
  done
}

main "$@"
