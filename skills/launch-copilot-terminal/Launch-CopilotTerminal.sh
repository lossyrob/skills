#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  Launch-CopilotTerminal.sh --title TITLE --color COLOR --cwd DIR
    (--prompt TEXT | --prompt-file FILE | --resume SESSION)
    [--copilot-arg ARG ...] [--copilot-command COMMAND]
    [--terminal auto|iterm2|terminal] [--window new|current] [--dry-run]
EOF
}

die() {
  printf 'launch-copilot-terminal: %s\n' "$*" >&2
  exit 1
}

require_value() {
  [[ $# -ge 2 ]] || die "Option '$1' requires a value."
}

shell_quote() {
  printf '%q' "$1"
}

title=
color=
cwd=$PWD
prompt=
prompt_file=
resume=
copilot_command=copilot
terminal=auto
window=new
dry_run=false
copilot_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title|-Title)
      require_value "$@"
      title=$2
      shift 2
      ;;
    --color|-Color)
      require_value "$@"
      color=$2
      shift 2
      ;;
    --cwd|-Cwd)
      require_value "$@"
      cwd=$2
      shift 2
      ;;
    --prompt|-Prompt)
      require_value "$@"
      prompt=$2
      shift 2
      ;;
    --prompt-file|-PromptFile)
      require_value "$@"
      prompt_file=$2
      shift 2
      ;;
    --resume|-Resume)
      require_value "$@"
      resume=$2
      shift 2
      ;;
    --copilot-arg|-CopilotArg)
      require_value "$@"
      copilot_args+=("$2")
      shift 2
      ;;
    --copilot-arg=*)
      copilot_args+=("${1#*=}")
      shift
      ;;
    --copilot-command|-CopilotCommand)
      require_value "$@"
      copilot_command=$2
      shift 2
      ;;
    --terminal|-Terminal)
      require_value "$@"
      terminal=$2
      shift 2
      ;;
    --terminal=*)
      terminal=${1#*=}
      shift
      ;;
    --window|-Window)
      require_value "$@"
      window=$2
      shift 2
      ;;
    --dry-run|-DryRun)
      dry_run=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown option '$1'."
      ;;
  esac
done

[[ -n $title ]] || die "Title is required."
[[ -n $color ]] || die "Color is required."
[[ $title != *$'\n'* && $color != *$'\n'* ]] || die "Title and color must be single-line values."
[[ $window == new || $window == current ]] || die "Window must be 'new' or 'current'."
[[ $(uname -s) == Darwin ]] || die "The Bash launcher requires macOS."
command -v osascript >/dev/null 2>&1 || die "AppleScript command 'osascript' was not found."

case "$terminal" in
  auto)
    if /usr/bin/open -Ra iTerm >/dev/null 2>&1 || /usr/bin/open -Ra iTerm2 >/dev/null 2>&1; then
      selected_terminal=iterm2
    else
      selected_terminal=terminal
    fi
    ;;
  iterm|iterm2|terminal2)
    if /usr/bin/open -Ra iTerm >/dev/null 2>&1 || /usr/bin/open -Ra iTerm2 >/dev/null 2>&1; then
      selected_terminal=iterm2
    else
      die "iTerm2 (Terminal2) is not installed."
    fi
    ;;
  terminal|terminal.app)
    selected_terminal=terminal
    ;;
  *)
    die "Terminal must be 'auto', 'iterm2', or 'terminal'."
    ;;
esac

mode_count=0
[[ -n $prompt ]] && ((mode_count += 1))
[[ -n $prompt_file ]] && ((mode_count += 1))
[[ -n $resume ]] && ((mode_count += 1))
[[ $mode_count -eq 1 ]] || die "Provide exactly one of --prompt, --prompt-file, or --resume."

[[ -d $cwd ]] || die "Working directory '$cwd' is not a directory."
resolved_cwd=$(cd "$cwd" && pwd -P)

if [[ $copilot_command == */* ]]; then
  [[ -x $copilot_command ]] || die "Copilot command '$copilot_command' is not executable."
  resolved_copilot=$copilot_command
else
  resolved_copilot=$(command -v "$copilot_command") || die "Copilot command '$copilot_command' was not found in PATH."
fi

launch_root=$HOME/.copilot/terminal-launches
mkdir -p "$launch_root"
launch_script=$(mktemp "$launch_root/launch.XXXXXX")
prompt_payload=

cleanup_on_error() {
  rm -f "$launch_script"
  [[ -z $prompt_payload ]] || rm -f "$prompt_payload"
}
trap cleanup_on_error EXIT

if [[ -n $prompt_file ]]; then
  [[ -f $prompt_file ]] || die "Prompt file '$prompt_file' was not found."
  prompt=$(<"$prompt_file")
fi

if [[ -z $resume ]]; then
  [[ -n ${prompt//[[:space:]]/} ]] || die "Prompt must not be empty."
  prompt_payload=$(mktemp "$launch_root/prompt.XXXXXX")
  chmod 600 "$prompt_payload"
  printf '%s' "$prompt" >"$prompt_payload"
fi

{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -u'
  printf 'launch_script=%s\n' "$(shell_quote "$launch_script")"
  printf '%s\n' 'rm -f "$launch_script"'
  printf 'cd %s\n' "$(shell_quote "$resolved_cwd")"
  printf 'printf "%%s" %s\n' "$(shell_quote $'\033]0;'"[$color] $title"$'\007')"
  printf 'copilot_command=%s\n' "$(shell_quote "$resolved_copilot")"
  printf '%s\n' 'copilot_args=('
  for arg in "${copilot_args[@]}"; do
    printf '  %s\n' "$(shell_quote "$arg")"
  done
  printf '%s\n' ')'

  if [[ -n $resume ]]; then
    printf '"$copilot_command" "${copilot_args[@]}" --resume %s\n' "$(shell_quote "$resume")"
  else
    printf 'prompt_file=%s\n' "$(shell_quote "$prompt_payload")"
    printf '%s\n' 'copilot_prompt=$(<"$prompt_file")'
    printf '%s\n' 'rm -f "$prompt_file"'
    printf '%s\n' '"$copilot_command" "${copilot_args[@]}" -i "$copilot_prompt"'
  fi

  printf '%s\n' 'status=$?'
  printf '%s\n' 'printf "\nCopilot exited with status %s. Starting a login shell...\n" "$status"'
  printf '%s\n' 'exec "${SHELL:-/bin/zsh}" -l'
} >"$launch_script"
chmod 700 "$launch_script"

launch_command="/bin/bash $(shell_quote "$launch_script")"
display_title="[$color] $title"

if [[ $dry_run == true ]]; then
  printf 'command: osascript\n'
  printf 'terminal: %s\n' "$selected_terminal"
  printf 'window: %s\n' "$window"
  printf 'title: %s\n' "$display_title"
  printf 'cwd: %s\n' "$resolved_cwd"
  printf 'launchScript: %s\n' "$launch_script"
  printf 'copilotCommand: %s\n' "$resolved_copilot"
  printf 'copilotArgs:'
  printf ' %q' "${copilot_args[@]}"
  printf '\n'
  if [[ -n $resume ]]; then
    printf 'resume: %s\n' "$resume"
  else
    printf 'promptFile: %s\n' "$prompt_payload"
  fi
  trap - EXIT
  exit 0
fi

if [[ $selected_terminal == iterm2 ]]; then
  osascript - "$launch_command" "$display_title" "$window" <<'APPLESCRIPT'
on run argv
  set launchCommand to item 1 of argv
  set displayTitle to item 2 of argv
  set windowMode to item 3 of argv

  tell application id "com.googlecode.iterm2"
    activate
    if windowMode is "current" and (count of windows) > 0 then
      tell current window
        create tab with default profile command launchCommand
        tell current session
          set name to displayTitle
        end tell
      end tell
    else
      set launchedWindow to (create window with default profile command launchCommand)
      tell current session of launchedWindow
        set name to displayTitle
      end tell
    end if
  end tell
end run
APPLESCRIPT
else
  osascript - "$launch_command" "$display_title" "$window" <<'APPLESCRIPT'
on run argv
  set launchCommand to item 1 of argv
  set displayTitle to item 2 of argv
  set windowMode to item 3 of argv

  tell application "Terminal"
    activate
  end tell

  if windowMode is "current" then
    tell application "System Events"
      tell process "Terminal"
        keystroke "t" using command down
      end tell
    end tell
    delay 0.2
    tell application "Terminal"
      set launchedTab to selected tab of front window
      do script launchCommand in launchedTab
      set custom title of launchedTab to displayTitle
    end tell
  else
    tell application "Terminal"
      set launchedTab to do script launchCommand
      set custom title of launchedTab to displayTitle
    end tell
  end if
end run
APPLESCRIPT
fi

trap - EXIT
printf "Launched Copilot terminal '%s' in %s via %s.\n" "$display_title" "$resolved_cwd" "$selected_terminal"
