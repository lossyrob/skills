---
name: launch-copilot-terminal
description: Launch a new terminal running Copilot CLI with a requested title, color label, and working directory. Supports macOS iTerm2/Terminal.app and Windows Terminal, prompt-driven sessions, existing-session resume, explicit terminal selection, and new/current window targeting.
compatibility: "Requires macOS with iTerm2 or Terminal.app and Bash, or Windows with Windows Terminal and PowerShell 5.1+; Copilot CLI must be on PATH."
---

# Launch Copilot Terminal

Use this skill when the user asks to launch, open, spawn, or start a new Copilot CLI terminal/session/window with a title, color, working directory, and initial prompt, or to resume an existing session in a new terminal.

## Behavior

- Launches Windows Terminal on Windows. On macOS, `terminal=auto` uses Terminal.app to avoid surprising
  iTerm2 Automation prompts; `terminal=iterm2` and `terminal=terminal` select explicitly. The macOS
  helper also accepts `iterm`, `terminal2`, and `terminal.app` aliases.
- By default the session opens in a separate window; `window=current` opens a tab in the current window.
- In prompt mode, starts Copilot CLI with `copilot -i <prompt>` so the prompt is submitted into an interactive session.
- In resume mode, starts Copilot CLI with `copilot --resume <session>` to reattach to an existing session interactively (no prompt is submitted).
- Sets the terminal title. Windows uses a real tab color; macOS includes the requested color as a title
  label (for example, `[green] Implementation`).
- Uses an explicitly provided working directory; if none is provided, use the current working directory.
- Leaves the terminal open after Copilot exits.
- Supports common color names and `#RRGGBB`/`RRGGBB` hex values.

## Required inputs

- `title`: the terminal title.
- `color`: a natural color name such as `green`, `blue`, or `purple`, or a hex color such as `#00ff00`.
- Exactly one of:
  - `prompt`: the prompt to submit to Copilot (prompt mode).
  - `promptFile`: path to a UTF-8 prompt file (prompt mode, useful for very long prompts).
  - `resume`: the session ID or exact session name to resume (resume mode).

## Optional inputs

- `cwd`: working directory for the launched session. Defaults to the current working directory.
- `copilotArgs`: extra Copilot CLI arguments, such as `--model gpt-5.5` or `--allow-all`. On macOS,
  pass each argument with a separate `--copilot-arg`.
- `copilotCommand`: alternate Copilot command path. Defaults to `copilot`.
- `terminal` (macOS): `auto` (default), `iterm2`, or `terminal`. Auto uses Terminal.app. Explicit iTerm2
  selection fails clearly when it is not installed.
- `window`: `new` (default) opens a separate terminal window; `current` opens a tab in the current
  window. Terminal.app may request macOS Accessibility permission the first time it creates a
  current-window tab; iTerm2 does not require GUI scripting for this operation.

## How to launch

Detect the host OS and use the matching bundled helper. Use the actual installed skill path; do not
assume the skill is installed under `~/.copilot/skills`. If the platform terminal or Copilot CLI is
unavailable, explain the missing prerequisite instead of attempting a launch.

### macOS

Run the bundled Bash helper:

```bash
skill_dir="/path/to/launch-copilot-terminal"
"$skill_dir/Launch-CopilotTerminal.sh" \
  --title "Implementation" \
  --color green \
  --cwd "/Users/rob/proj/repo" \
  --terminal auto \
  --prompt "Implement the requested change and validate it."
```

`--terminal auto` selects Terminal.app. Use `--terminal iterm2` (also `iterm` / `terminal2`) to require
iTerm2.

For a long prompt and extra Copilot flags:

```bash
"$skill_dir/Launch-CopilotTerminal.sh" \
  --title "Autonomous worker" \
  --color purple \
  --cwd "/Users/rob/proj/repo" \
  --terminal iterm2 \
  --prompt-file "/path/to/prompt.md" \
  --copilot-arg=--allow-all \
  --copilot-arg=--model \
  --copilot-arg=gpt-5.5
```

Resume in a tab in the current macOS terminal window:

```bash
"$skill_dir/Launch-CopilotTerminal.sh" \
  --title "Branch: my session [a1b2c3d4]" \
  --color purple \
  --cwd "/Users/rob/proj/repo" \
  --terminal auto \
  --resume "a1b2c3d4-5678-90ab-cdef-1234567890ab" \
  --window current
```

### Windows

```powershell
$skillDir = "C:\path\to\launch-copilot-terminal"
& (Join-Path $skillDir "Launch-CopilotTerminal.ps1") `
  -Title "Implementation" `
  -Color green `
  -Cwd "C:\Users\robemanuele\proj\streamliner\streamliner" `
  -Prompt @'
Implement the requested change and validate it.
'@
```

For extra Copilot flags:

```powershell
$skillDir = "C:\path\to\launch-copilot-terminal"
& (Join-Path $skillDir "Launch-CopilotTerminal.ps1") `
  -Title "Autonomous worker" `
  -Color "#00ff00" `
  -Cwd "C:\path\to\repo" `
  -CopilotArgs @("--allow-all", "--model", "gpt-5.5") `
  -Prompt @'
Run the implementation task autonomously.
'@
```

For very long prompts or prompts that may contain a PowerShell here-string terminator, write the prompt to a temporary file and pass `-PromptFile`.

To resume an existing Copilot session in a new tab inside the current Windows Terminal window:

```powershell
$skillDir = "C:\path\to\launch-copilot-terminal"
& (Join-Path $skillDir "Launch-CopilotTerminal.ps1") `
  -Title "Branch: my session [a1b2c3d4]" `
  -Color purple `
  -Cwd "C:\path\to\repo" `
  -Resume "a1b2c3d4-5678-90ab-cdef-1234567890ab" `
  -Window current
```

`-Resume` accepts either a session ID or an exact session name (matching `--resume` on the Copilot CLI). Use a session ID when names may be ambiguous.

## Notes

- The first explicit iTerm2 launch may trigger a macOS Automation prompt for
  **GitHub Copilot.app → iTerm.app**. Choose **Allow** once, or enable it later in **System Settings →
  Privacy & Security → Automation**. macOS owns this consent prompt; the launcher cannot suppress it.
  The iTerm2 AppleScript allows up to ten minutes for the one-time decision so worker startup does not
  fail with `-1712` while the prompt is pending.
- On Windows, prefer `-Prompt` with a single-quoted here-string for normal multiline prompts.
- Use `--dry-run` on macOS or `-DryRun` on Windows to inspect the generated launch without opening a terminal.
- Do not use `copilot -p` for this workflow because it runs non-interactively and exits.
- Quote titles, paths, and prompts explicitly.
- Resume mode does not submit a prompt; the new tab drops directly into the resumed interactive session.
- Current-window mode targets the current iTerm2/Terminal.app window on macOS or the most recently used
  Windows Terminal window (`wt -w 0`) on Windows.
