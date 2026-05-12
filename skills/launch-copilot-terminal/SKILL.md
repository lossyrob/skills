---
name: launch-copilot-terminal
description: Launch a new Windows Terminal window running Copilot CLI with a requested title, tab color, working directory, and seeded interactive prompt.
compatibility: "Requires Windows, Windows Terminal (wt.exe), PowerShell 5.1+ or PowerShell 7+, and Copilot CLI on PATH."
---

# Launch Copilot Terminal

Use this skill when the user asks to launch, open, spawn, or start a new Copilot CLI terminal/session/window with a title, color, working directory, and initial prompt.

## Behavior

- Launches a separate Windows Terminal window, not a tab in an existing window.
- Starts Copilot CLI with `copilot -i <prompt>` so the prompt is submitted into an interactive session.
- Sets the Windows Terminal tab title and tab color.
- Uses an explicitly provided working directory; if none is provided, use the current working directory.
- Leaves the terminal open after Copilot exits.
- Supports common color names and `#RRGGBB`/`RRGGBB` hex values.

## Required inputs

- `title`: the Windows Terminal tab title.
- `color`: a natural color name such as `green`, `blue`, or `purple`, or a hex color such as `#00ff00`.
- `prompt`: the prompt to submit to Copilot.

## Optional inputs

- `cwd`: working directory for the launched session. Defaults to the current working directory.
- `copilotArgs`: extra Copilot CLI arguments, such as `--model gpt-5.5` or `--allow-all`.
- `promptFile`: path to a UTF-8 prompt file for very long prompts or prompts that may contain a PowerShell here-string terminator.
- `copilotCommand`: alternate Copilot command path. Defaults to `copilot`.

## How to launch

Use this skill only on Windows. If Windows Terminal or Copilot CLI is unavailable, explain the missing prerequisite instead of attempting a launch.

Run the bundled PowerShell helper from this skill directory. Use the actual installed skill path; do not assume the skill is installed under `$HOME\.copilot\skills`.

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

## Notes

- Prefer `-Prompt` with a single-quoted here-string for normal multiline prompts.
- Use `-DryRun` to inspect the generated launch command without opening a terminal.
- Do not use `copilot -p` for this workflow because it runs non-interactively and exits.
- Quote titles, paths, and prompts explicitly.
