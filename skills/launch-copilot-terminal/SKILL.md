---
name: launch-copilot-terminal
description: Launch a new Windows Terminal tab running Copilot CLI with a requested title, tab color, and working directory. Supports a prompt-driven interactive session, an existing-session resume, and targeting either a separate window or the current Windows Terminal window.
compatibility: "Requires Windows, Windows Terminal (wt.exe), PowerShell 5.1+ or PowerShell 7+, and Copilot CLI on PATH."
---

# Launch Copilot Terminal

Use this skill when the user asks to launch, open, spawn, or start a new Copilot CLI terminal/session/window with a title, color, working directory, and initial prompt, or to resume an existing session in a new terminal.

## Behavior

- Launches a new Windows Terminal tab. By default the tab opens in a separate window; pass `-Window current` to open the tab in the current Windows Terminal window instead.
- In prompt mode, starts Copilot CLI with `copilot -i <prompt>` so the prompt is submitted into an interactive session.
- In resume mode, starts Copilot CLI with `copilot --resume <session>` to reattach to an existing session interactively (no prompt is submitted).
- Sets the Windows Terminal tab title and tab color.
- Uses an explicitly provided working directory; if none is provided, use the current working directory.
- Leaves the terminal open after Copilot exits.
- Supports common color names and `#RRGGBB`/`RRGGBB` hex values.

## Required inputs

- `title`: the Windows Terminal tab title.
- `color`: a natural color name such as `green`, `blue`, or `purple`, or a hex color such as `#00ff00`.
- Exactly one of:
  - `prompt`: the prompt to submit to Copilot (prompt mode).
  - `promptFile`: path to a UTF-8 prompt file (prompt mode, useful for very long prompts).
  - `resume`: the session ID or exact session name to resume (resume mode).

## Optional inputs

- `cwd`: working directory for the launched session. Defaults to the current working directory.
- `copilotArgs`: extra Copilot CLI arguments, such as `--model gpt-5.5` or `--allow-all`.
- `copilotCommand`: alternate Copilot command path. Defaults to `copilot`.
- `window`: `new` (default) opens the tab in a separate Windows Terminal window; `current` opens the tab in the current Windows Terminal window (`wt -w 0`).

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

- Prefer `-Prompt` with a single-quoted here-string for normal multiline prompts.
- Use `-DryRun` to inspect the generated launch command without opening a terminal.
- Do not use `copilot -p` for this workflow because it runs non-interactively and exits.
- Quote titles, paths, and prompts explicitly.
- Resume mode does not submit a prompt; the new tab drops directly into the resumed interactive session.
- `-Window current` targets the most recently used Windows Terminal window (`wt -w 0`); use it when the caller wants the new tab to land beside the current session.
