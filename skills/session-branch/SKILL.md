---
name: session-branch
description: Branch the current session, creating a new session that inherits conversation history up to the current point while preserving the original session intact. This skill should be used when the user wants to create a new session branch for experimentation or parallel development without affecting the original session.
compatibility: "Requires Python 3. Includes Bash instructions for macOS/Linux/Git Bash and PowerShell instructions for Windows."
---
# Session Branch Skill

Branch the current session, creating a new session that inherits conversation history up to the current point while preserving the original session intact.

## Trigger

Use this skill when the user says:
- "branch", "branch session", "fork session"
- "create a branch from here"
- "save this point and branch"

If the branch request also includes "launch in terminal", "open in terminal", "in a new tab", or similar, follow the [Launch in Terminal (Optional)](#launch-in-terminal-optional) flow instead of the default success report. This Windows-only mode opens the branched session in a new Windows Terminal tab inside the current window using the [`launch-copilot-terminal`](../launch-copilot-terminal/SKILL.md) helper.

## Bundled scripts

This skill ships with helper scripts in `scripts/` next to this `SKILL.md`. They are the canonical implementation of the heavy lifting; the snippets below just orchestrate them.

| Script | Purpose |
|---|---|
| `scripts/branch_session.py` | Copy a session, rewrite metadata, and reset rewind/checkpoints. |
| `scripts/truncate_session.py` | Drop the last N user turns from the branched session's `events.jsonl`. |
| `scripts/Launch-BranchedSession.ps1` | (Windows-only) Open the branched session in a new Windows Terminal tab inside the current window via the [`launch-copilot-terminal`](../launch-copilot-terminal/SKILL.md) helper. |

Resolve the skill directory however your environment exposes it (e.g. the directory containing this `SKILL.md`). Examples below use `$SKILL_DIR` (Bash) or `$PSScriptRoot` after dot-sourcing / `Split-Path` of the SKILL.md path; substitute your actual lookup.

## Instructions

When invoked, perform the following steps. Use PowerShell on Windows and Bash on macOS/Linux.

### 1. Identify Current Session

The current session ID is in `<session_context>` → session folder path.

### 2. Run Branch Script

Generate a new session ID, then invoke `scripts/branch_session.py` to copy the session and rewrite metadata. Capture the printed `NEW_SESSION_ID`, `NEW_SESSION_NAME`, and `NEW_SESSION_PATH` for use in later steps.

#### Bash

```bash
set -euo pipefail

CURRENT_SESSION_ID="<current-session-id>"
STATE_DIR="$HOME/.copilot/session-state"
CURRENT_SESSION="$STATE_DIR/$CURRENT_SESSION_ID"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)}"
if [ -z "$PYTHON_BIN" ]; then
  echo "Python 3 is required to branch a session" >&2
  exit 1
fi
NEW_SESSION_ID=$("$PYTHON_BIN" -c 'import uuid; print(uuid.uuid4())')
NEW_SESSION="$STATE_DIR/$NEW_SESSION_ID"

# $SKILL_DIR is the directory containing this SKILL.md.
"$PYTHON_BIN" "$SKILL_DIR/scripts/branch_session.py" \
  "$CURRENT_SESSION" "$NEW_SESSION" "$CURRENT_SESSION_ID" "$NEW_SESSION_ID"
```

The script prints three `KEY=value` lines (`NEW_SESSION_ID`, `NEW_SESSION_NAME`, `NEW_SESSION_PATH`) on stdout. Capture them with a small loop or `eval` if you need them as shell variables.

#### PowerShell

```powershell
$ErrorActionPreference = "Stop"

$CURRENT_SESSION_ID = "<current-session-id>"
$STATE_DIR = Join-Path $HOME ".copilot\session-state"
$CURRENT_SESSION = Join-Path $STATE_DIR $CURRENT_SESSION_ID
$NEW_SESSION_ID = [guid]::NewGuid().ToString()
$NEW_SESSION = Join-Path $STATE_DIR $NEW_SESSION_ID

$pythonCommand = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction SilentlyContinue }
if (-not $pythonCommand) { throw "Python 3 is required to branch a session." }
$PYTHON_BIN = $pythonCommand.Source

# $SKILL_DIR is the directory containing this SKILL.md.
$branchOutput = & $PYTHON_BIN (Join-Path $SKILL_DIR "scripts\branch_session.py") `
    $CURRENT_SESSION $NEW_SESSION $CURRENT_SESSION_ID $NEW_SESSION_ID

$branchValues = @{}
foreach ($line in $branchOutput) {
    if ($line -match '^([A-Z_]+)=(.*)$') {
        $branchValues[$Matches[1]] = $Matches[2]
    }
}
$NEW_SESSION_NAME = $branchValues['NEW_SESSION_NAME']
$NEW_SESSION_PATH = $branchValues['NEW_SESSION_PATH']
# $NEW_SESSION_ID was generated locally above; keep using that variable.
```

### 3. Report Success

Tell the user the **exact commands** to drop into the new session. Include the `cd` to the working directory.

**Detect CLI flags**: Before reporting, detect what flags the current session was launched with. If flag detection fails, omit the flags.

#### Bash

```bash
COPILOT_FLAGS=$(cat /proc/$PPID/cmdline 2>/dev/null | tr '\0' ' ' | grep -Eo '(--yolo|--allow-all|--alt-screen|--model [^ ]+)' | tr '\n' ' ' || echo "")
```

#### PowerShell

```powershell
$COPILOT_FLAGS = ""
try {
    $currentProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
    if ($currentProcess -and $currentProcess.ParentProcessId) {
        $parentProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($currentProcess.ParentProcessId)" -ErrorAction SilentlyContinue
        $parentCommand = if ($parentProcess) { $parentProcess.CommandLine } else { "" }
        $flags = [regex]::Matches($parentCommand, '(--yolo|--allow-all|--alt-screen|--model\s+\S+)') | ForEach-Object { $_.Value }
        if ($flags) { $COPILOT_FLAGS = ($flags -join ' ') }
    }
} catch {
    $COPILOT_FLAGS = ""
}
```

Include those flags in the resume command. Use a shell-appropriate command separator: `&&` in Bash or PowerShell 7+, and `;` in Windows PowerShell 5.1.

```
✅ Session branched successfully!

To start working in the new session:

    cd <cwd> && copilot --resume="<new-session-name>" <detected-flags>
    cd <cwd>; copilot --resume="<new-session-name>" <detected-flags>   # Windows PowerShell 5.1

To return to this session later:

    cd <original-cwd> && copilot --resume=<current-session-name-or-id> <detected-flags>
    cd <original-cwd>; copilot --resume=<current-session-name-or-id> <detected-flags>   # Windows PowerShell 5.1

If name matching is ambiguous for any reason, resume by ID:

    cd <cwd> && copilot --resume=<new-session-id> <detected-flags>
    cd <cwd>; copilot --resume=<new-session-id> <detected-flags>   # Windows PowerShell 5.1
```

If a worktree was created, the `cd` should point to the worktree directory instead:

```
    cd <worktree-dir> && copilot --resume="<new-session-name>" <detected-flags>
    cd <worktree-dir>; copilot --resume="<new-session-name>" <detected-flags>   # Windows PowerShell 5.1
```

**Important:** Copilot CLI now uses the `name` field in `workspace.yaml` for
session picker labels and exact `--resume="<name>"` matching. The branch script
sets `name` to `Branch: <original-title> [<new-id-prefix>]` and `user_named: true`
so the branch is visually distinct and does not collide with the original title.
To identify all branches later, the user can run:

```bash
grep -l 'branch_of' ~/.copilot/session-state/*/workspace.yaml | while read f; do
  echo "---"
  cat "$f"
done
```

```powershell
Get-ChildItem (Join-Path $HOME ".copilot\session-state\*\workspace.yaml") | ForEach-Object {
    $content = Get-Content -LiteralPath $_.FullName -Raw
    if ($content -match 'branch_of') {
        Write-Output "---"
        Write-Output $content
    }
}
```

### 4. Launch in Terminal (Optional)

Only run this step if the user explicitly asked to launch the branched session in a terminal (e.g., "branch and launch in terminal", "launch in terminal", "open in a new tab"). When this mode is requested, **replace** the standard "Report Success" output with a minimal launch announcement (no resume commands, no branch listing snippets, no worktree resume hints).

**Platform**: Windows-only. The launch helper depends on Windows Terminal (`wt.exe`) and the [`launch-copilot-terminal`](../launch-copilot-terminal/SKILL.md) skill. On Bash/macOS/Linux, do **not** attempt the launch — fall back to the standard "Report Success" output and tell the user that launch-in-terminal is currently Windows-only.

**Ordering**: If the user also asked to truncate (e.g., "branch from N turns ago and launch in terminal"), perform Step 5 (Truncation) **before** running this step, so the resumed session loads the truncated state.

#### Run the wrapper

```powershell
# $SKILL_DIR is the directory containing this SKILL.md.
# $WORKTREE_DIR is set only if the Worktree Branching section ran.
# $LAUNCH_COLOR is "purple" by default; override if the user specified one.

$launchArgs = @{
    CurrentSession = $CURRENT_SESSION
    NewSessionId   = $NEW_SESSION_ID
    NewSessionName = $NEW_SESSION_NAME
}
if ($WORKTREE_DIR)  { $launchArgs.WorktreeDir = $WORKTREE_DIR }
if ($LAUNCH_COLOR)  { $launchArgs.Color       = $LAUNCH_COLOR }

& (Join-Path $SKILL_DIR "scripts\Launch-BranchedSession.ps1") @launchArgs
$launchExit = $LASTEXITCODE
```

`Launch-BranchedSession.ps1` handles the full flow: locates the `launch-copilot-terminal` helper (sibling skill dir, default plugin install path, or recursive fallback under `~/.copilot`); detects parent CLI flags (`--yolo`, `--allow-all`, `--alt-screen`, `--model …`) and forwards them on resume; resolves the working directory (worktree dir, original session `cwd:`, or current location as last resort); calls the helper with `-Resume <new-id> -Window current`; and emits the minimal launch-announcement message on success.

The wrapper resumes by **session ID** (not name) to avoid name collisions, and uses `-Window current` (`wt -w 0`) so the new tab lands beside the current Copilot session.

#### On failure, fall back

The wrapper exits non-zero (`2` = non-Windows, `3` = helper not found, `4` = helper invocation failed, plus any error from `Launch-CopilotTerminal.ps1` itself) and writes a warning. When `$launchExit -ne 0`, fall back to the standard Step 3 "Report Success" output so the user still gets working resume instructions.

```powershell
if ($launchExit -ne 0) {
    # Emit the standard Step 3 report-success block.
}
```

#### Minimal success message (when launch succeeds)

The wrapper prints these two lines on success; do not duplicate them. Do not echo any resume commands, branch listing instructions, or worktree resume hints in this mode.

```
OK Branched session: <NEW_SESSION_ID>
-> Launching it in a new Windows Terminal tab in this window...
```

### 5. Truncation (Only If Requested)

If the user says "branch from N turns ago", invoke `scripts/truncate_session.py` against the branched session to remove the last N user turns from `events.jsonl`. Run this **before** Step 4 if launch-in-terminal was also requested.

#### Bash

```bash
# $SKILL_DIR is the directory containing this SKILL.md.
"$PYTHON_BIN" "$SKILL_DIR/scripts/truncate_session.py" "$NEW_SESSION" N
```

#### PowerShell

```powershell
# $SKILL_DIR is the directory containing this SKILL.md.
& $PYTHON_BIN (Join-Path $SKILL_DIR "scripts\truncate_session.py") $NEW_SESSION N
```

The script counts `user.message` events as turns and exits non-zero if `N` exceeds the number of available turns.

## Notes

- Both sessions are fully independent after branching
- The original session is never modified
- Rewind/checkpoint history starts fresh in the branch
- Session database (session.db) is removed in the branch to avoid stale references
- Stale `inuse.*.lock` files are removed from the branch so it does not inherit the original session's in-use marker
- `name` in workspace.yaml is the Copilot CLI resume title. The branch title includes the new session ID prefix to keep exact name matching unambiguous
- `user_named: true` keeps Copilot from replacing the branch title with the same auto-generated title as the original session
- `summary` is updated for older picker/search surfaces, but it may still be regenerated later and should not be the only branch identifier
- `branch_of` and `branch_note` fields in workspace.yaml track lineage (copilot preserves these custom fields)

## Worktree Branching (Optional)

If the user says "branch into a worktree" or "branch with worktree for X", also create a git worktree so the new session works in an isolated directory:

#### Bash

```bash
BRANCH_NAME="donna/$FEATURE_SLUG"
WORKTREE_DIR="$HOME/proj/pal-trees/$FEATURE_SLUG"

# Create branch and worktree
git worktree add "$WORKTREE_DIR" -b "$BRANCH_NAME"

# Install dependencies in the worktree
cd "$WORKTREE_DIR/donna" && npm install

# Update the new session's cwd to point at the worktree
sed -i "s|^cwd: .*|cwd: $WORKTREE_DIR|" "$NEW_SESSION/workspace.yaml"
```

Then tell the user:
```
✅ Session branched with worktree!

Worktree: ~/proj/pal-trees/<feature>
Branch: donna/<feature>

To start working:
    cd ~/proj/pal-trees/<feature> && copilot --resume=<new-session-id>
```

#### PowerShell

```powershell
$BRANCH_NAME = "donna/$FEATURE_SLUG"
$WORKTREE_DIR = Join-Path $HOME "proj\pal-trees\$FEATURE_SLUG"

git worktree add $WORKTREE_DIR -b $BRANCH_NAME

Push-Location (Join-Path $WORKTREE_DIR "donna")
npm install
Pop-Location

$workspacePath = Join-Path $NEW_SESSION "workspace.yaml"
$yaml = Get-Content -LiteralPath $workspacePath -Raw
$yaml = $yaml -replace '(?m)^cwd: .*', "cwd: $WORKTREE_DIR"
Set-Content -LiteralPath $workspacePath -Value $yaml -NoNewline
```

Then tell the user:
```powershell
✅ Session branched with worktree!

Worktree: ~\proj\pal-trees\<feature>
Branch: donna/<feature>

To start working:
    cd ~\proj\pal-trees\<feature>; copilot --resume=<new-session-id>
```
