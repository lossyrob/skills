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

## Instructions

When invoked, perform the following steps. Use PowerShell on Windows and Bash on macOS/Linux. Keep the branch operation in a single script for the selected shell so session copying, metadata rewrite, and cleanup happen together.

### 1. Identify Current Session

The current session ID is in `<session_context>` → session folder path.

### 2. Run Branch Script

Run the script for the current shell, substituting `CURRENT_SESSION_ID` with the actual value.

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

"$PYTHON_BIN" - "$CURRENT_SESSION" "$NEW_SESSION" "$CURRENT_SESSION_ID" "$NEW_SESSION_ID" <<'PY'
import datetime as dt
import json
import shutil
import sys
from pathlib import Path

current_session = Path(sys.argv[1])
new_session = Path(sys.argv[2])
current_session_id = sys.argv[3]
new_session_id = sys.argv[4]

workspace_path = current_session / "workspace.yaml"
if not workspace_path.exists():
    raise SystemExit(f"Missing workspace metadata: {workspace_path}")
if new_session.exists():
    raise SystemExit(f"Branch destination already exists: {new_session}")


def parse_scalar(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value[1:-1]
    if len(value) >= 2 and value[0] == "'" and value[-1] == "'":
        return value[1:-1].replace("''", "'")
    return value


def read_top_level_fields(path):
    fields = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line and not line.startswith(" ") and ":" in line:
            key, value = line.split(":", 1)
            fields[key] = parse_scalar(value)
    return fields


def yaml_string(value):
    return json.dumps(value, ensure_ascii=True)


def compact(value, max_len=72):
    value = " ".join((value or "").split())
    if len(value) <= max_len:
        return value
    return value[: max_len - 3].rstrip() + "..."


def set_top_level(lines, key, value):
    prefix = f"{key}:"
    for index, line in enumerate(lines):
        if line.startswith(prefix):
            lines[index] = f"{key}: {value}"
            return
    lines.append(f"{key}: {value}")


current_fields = read_top_level_fields(workspace_path)
base_title = (
    current_fields.get("name")
    or current_fields.get("summary")
    or f"Session {current_session_id[:8]}"
)
branch_title = f"Branch: {compact(base_title)} [{new_session_id[:8]}]"
now = dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")

# Copy the session, then rewrite identity and title metadata in the branch.
shutil.copytree(current_session, new_session)

new_workspace_path = new_session / "workspace.yaml"
workspace_lines = new_workspace_path.read_text(encoding="utf-8").splitlines()
set_top_level(workspace_lines, "id", new_session_id)
set_top_level(workspace_lines, "name", yaml_string(branch_title))
set_top_level(workspace_lines, "user_named", "true")
set_top_level(workspace_lines, "summary", yaml_string(branch_title))
set_top_level(workspace_lines, "created_at", now)
set_top_level(workspace_lines, "updated_at", now)
set_top_level(workspace_lines, "branch_of", current_session_id)
set_top_level(
    workspace_lines,
    "branch_note",
    yaml_string(f"Branched from: {base_title} ({current_session_id})"),
)
new_workspace_path.write_text("\n".join(workspace_lines) + "\n", encoding="utf-8")

# Fix session.start event metadata to reference the new session ID.
events_path = new_session / "events.jsonl"
if events_path.exists():
    rewritten_events = []
    for line in events_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        event = json.loads(line)
        if event.get("type") == "session.start":
            data = event.setdefault("data", {})
            data["sessionId"] = new_session_id
            if "alreadyInUse" in data:
                data["alreadyInUse"] = False
            for key in ("name", "title", "summary"):
                if key in data:
                    data[key] = branch_title
        rewritten_events.append(json.dumps(event, separators=(",", ":"), ensure_ascii=False))
    events_path.write_text("\n".join(rewritten_events) + "\n", encoding="utf-8")

# Reset rewind snapshots (they reference old event state).
rewind_dir = new_session / "rewind-snapshots"
rewind_dir.mkdir(exist_ok=True)
(rewind_dir / "index.json").write_text(
    '{"version":1,"snapshots":[],"filePathMap":{}}\n',
    encoding="utf-8",
)
backup_dir = rewind_dir / "backups"
if backup_dir.exists():
    for child in backup_dir.iterdir():
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()

# Reset per-session database and stale in-use locks.
for path in [new_session / "session.db", *new_session.glob("inuse.*.lock")]:
    if path.exists():
        path.unlink()

# Reset checkpoints.
checkpoint_dir = new_session / "checkpoints"
checkpoint_dir.mkdir(exist_ok=True)
(checkpoint_dir / "index.md").write_text(
    "# Checkpoint History\n\n"
    "Checkpoints are listed in chronological order. Checkpoint 1 is the oldest, higher numbers are more recent.\n\n"
    "| # | Title | File |\n"
    "|---|-------|------|\n",
    encoding="utf-8",
)

print(f"NEW_SESSION_ID={new_session_id}")
print(f"NEW_SESSION_NAME={branch_title}")
print(f"NEW_SESSION_PATH={new_session}")
PY
```

#### PowerShell

```powershell
$ErrorActionPreference = "Stop"

$CURRENT_SESSION_ID = "<current-session-id>"
$STATE_DIR = Join-Path $HOME ".copilot\session-state"
$CURRENT_SESSION = Join-Path $STATE_DIR $CURRENT_SESSION_ID
$NEW_SESSION_ID = [guid]::NewGuid().ToString()
$NEW_SESSION = Join-Path $STATE_DIR $NEW_SESSION_ID

$pythonCommand = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $pythonCommand) {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
}
if (-not $pythonCommand) {
    throw "Python 3 is required to branch a session."
}
$PYTHON_BIN = $pythonCommand.Source

$branchScript = @'
import datetime as dt
import json
import shutil
import sys
from pathlib import Path

current_session = Path(sys.argv[1])
new_session = Path(sys.argv[2])
current_session_id = sys.argv[3]
new_session_id = sys.argv[4]

workspace_path = current_session / "workspace.yaml"
if not workspace_path.exists():
    raise SystemExit(f"Missing workspace metadata: {workspace_path}")
if new_session.exists():
    raise SystemExit(f"Branch destination already exists: {new_session}")


def parse_scalar(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value[1:-1]
    if len(value) >= 2 and value[0] == "'" and value[-1] == "'":
        return value[1:-1].replace("''", "'")
    return value


def read_top_level_fields(path):
    fields = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line and not line.startswith(" ") and ":" in line:
            key, value = line.split(":", 1)
            fields[key] = parse_scalar(value)
    return fields


def yaml_string(value):
    return json.dumps(value, ensure_ascii=True)


def compact(value, max_len=72):
    value = " ".join((value or "").split())
    if len(value) <= max_len:
        return value
    return value[: max_len - 3].rstrip() + "..."


def set_top_level(lines, key, value):
    prefix = f"{key}:"
    for index, line in enumerate(lines):
        if line.startswith(prefix):
            lines[index] = f"{key}: {value}"
            return
    lines.append(f"{key}: {value}")


current_fields = read_top_level_fields(workspace_path)
base_title = (
    current_fields.get("name")
    or current_fields.get("summary")
    or f"Session {current_session_id[:8]}"
)
branch_title = f"Branch: {compact(base_title)} [{new_session_id[:8]}]"
now = dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")

shutil.copytree(current_session, new_session)

new_workspace_path = new_session / "workspace.yaml"
workspace_lines = new_workspace_path.read_text(encoding="utf-8").splitlines()
set_top_level(workspace_lines, "id", new_session_id)
set_top_level(workspace_lines, "name", yaml_string(branch_title))
set_top_level(workspace_lines, "user_named", "true")
set_top_level(workspace_lines, "summary", yaml_string(branch_title))
set_top_level(workspace_lines, "created_at", now)
set_top_level(workspace_lines, "updated_at", now)
set_top_level(workspace_lines, "branch_of", current_session_id)
set_top_level(
    workspace_lines,
    "branch_note",
    yaml_string(f"Branched from: {base_title} ({current_session_id})"),
)
new_workspace_path.write_text("\n".join(workspace_lines) + "\n", encoding="utf-8")

events_path = new_session / "events.jsonl"
if events_path.exists():
    rewritten_events = []
    for line in events_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        event = json.loads(line)
        if event.get("type") == "session.start":
            data = event.setdefault("data", {})
            data["sessionId"] = new_session_id
            if "alreadyInUse" in data:
                data["alreadyInUse"] = False
            for key in ("name", "title", "summary"):
                if key in data:
                    data[key] = branch_title
        rewritten_events.append(json.dumps(event, separators=(",", ":"), ensure_ascii=False))
    events_path.write_text("\n".join(rewritten_events) + "\n", encoding="utf-8")

rewind_dir = new_session / "rewind-snapshots"
rewind_dir.mkdir(exist_ok=True)
(rewind_dir / "index.json").write_text(
    '{"version":1,"snapshots":[],"filePathMap":{}}\n',
    encoding="utf-8",
)
backup_dir = rewind_dir / "backups"
if backup_dir.exists():
    for child in backup_dir.iterdir():
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()

for path in [new_session / "session.db", *new_session.glob("inuse.*.lock")]:
    if path.exists():
        path.unlink()

checkpoint_dir = new_session / "checkpoints"
checkpoint_dir.mkdir(exist_ok=True)
(checkpoint_dir / "index.md").write_text(
    "# Checkpoint History\n\n"
    "Checkpoints are listed in chronological order. Checkpoint 1 is the oldest, higher numbers are more recent.\n\n"
    "| # | Title | File |\n"
    "|---|-------|------|\n",
    encoding="utf-8",
)

print(f"NEW_SESSION_ID={new_session_id}")
print(f"NEW_SESSION_NAME={branch_title}")
print(f"NEW_SESSION_PATH={new_session}")
'@

$branchScript | & $PYTHON_BIN - $CURRENT_SESSION $NEW_SESSION $CURRENT_SESSION_ID $NEW_SESSION_ID
```

Use the printed `NEW_SESSION_ID`, `NEW_SESSION_NAME`, and `NEW_SESSION_PATH` values in the success message.

When invoking PowerShell from the agent, capture the printed values into variables for use in later steps. For example, run the branch script and parse its `key=value` output:

```powershell
$branchOutput = $branchScript | & $PYTHON_BIN - $CURRENT_SESSION $NEW_SESSION $CURRENT_SESSION_ID $NEW_SESSION_ID
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

**Platform**: Windows-only. It depends on Windows Terminal (`wt.exe`) and the [`launch-copilot-terminal`](../launch-copilot-terminal/SKILL.md) helper. If the user is on Bash/macOS/Linux, do **not** attempt the launch — fall back to the standard "Report Success" output and tell the user that launch-in-terminal is currently Windows-only.

**Ordering**: If the user also asked to truncate (e.g., "branch from N turns ago and launch in terminal"), perform Step 5 (Truncation) **before** running this step, so the resumed session loads the truncated state.

#### Step 4a — Locate the launch-copilot-terminal helper

The plugin install location varies between hosts. Try the following in order, take the first existing path:

```powershell
$LAUNCH_SCRIPT_PATH = $null
$candidatePaths = @(
    # Sibling skill in the same checked-out repo as session-branch
    (Join-Path (Split-Path -Parent $PSScriptRoot) "launch-copilot-terminal\Launch-CopilotTerminal.ps1"),
    # Default plugin install path
    (Join-Path $HOME ".copilot\skills\launch-copilot-terminal\Launch-CopilotTerminal.ps1")
)
foreach ($candidate in $candidatePaths) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        $LAUNCH_SCRIPT_PATH = (Resolve-Path -LiteralPath $candidate).ProviderPath
        break
    }
}
if (-not $LAUNCH_SCRIPT_PATH) {
    $found = Get-ChildItem -Path (Join-Path $HOME ".copilot") -Recurse -Filter "Launch-CopilotTerminal.ps1" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { $LAUNCH_SCRIPT_PATH = $found.FullName }
}
```

If `$LAUNCH_SCRIPT_PATH` is still `$null`, fall back to the standard "Report Success" output and tell the user the launch helper was not available.

#### Step 4b — Detect CLI flags

Detect the same way Step 3 does. The launch helper preserves these on the resumed session.

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

$COPILOT_FLAGS_ARRAY = @()
if (-not [string]::IsNullOrWhiteSpace($COPILOT_FLAGS)) {
    $COPILOT_FLAGS_ARRAY = $COPILOT_FLAGS.Trim() -split '\s+'
}
```

#### Step 4c — Resolve title, color, and cwd

- **Title**: use `$NEW_SESSION_NAME` from Step 2 (it already contains the new ID prefix and is safe as both a `wt` tab title and a Copilot resume target).
- **Color**: default `purple` to make branched sessions visually distinct. If the user requested a specific color (e.g., "launch in terminal in green"), use that instead.
- **Cwd**: if a worktree was created (see "Worktree Branching" below), use that worktree directory. Otherwise read `cwd:` from the original session's `workspace.yaml`:

```powershell
$LAUNCH_COLOR = "purple"   # override if the user requested a specific color
$LAUNCH_CWD   = $null
if ($WORKTREE_DIR -and (Test-Path -LiteralPath $WORKTREE_DIR -PathType Container)) {
    $LAUNCH_CWD = (Resolve-Path -LiteralPath $WORKTREE_DIR).ProviderPath
} else {
    $workspacePath = Join-Path $CURRENT_SESSION "workspace.yaml"
    foreach ($line in Get-Content -LiteralPath $workspacePath -Encoding UTF8) {
        if ($line -match '^cwd:\s*(.*)$') {
            $LAUNCH_CWD = $Matches[1].Trim().Trim('"').Trim("'")
            break
        }
    }
}
if (-not $LAUNCH_CWD -or -not (Test-Path -LiteralPath $LAUNCH_CWD -PathType Container)) {
    $LAUNCH_CWD = (Get-Location).ProviderPath
}
```

#### Step 4d — Launch

```powershell
try {
    & $LAUNCH_SCRIPT_PATH `
        -Title $NEW_SESSION_NAME `
        -Color $LAUNCH_COLOR `
        -Cwd $LAUNCH_CWD `
        -Resume $NEW_SESSION_ID `
        -Window current `
        -CopilotArgs $COPILOT_FLAGS_ARRAY
} catch {
    # Launch helper failed (e.g., wt.exe missing, invalid cwd, wt.exe non-zero exit).
    # Fall back to the standard Step 3 output and surface the failure reason.
    Write-Warning "Launch helper failed: $($_.Exception.Message). Falling back to resume instructions."
    # Then emit the standard Report Success block from Step 3.
    return
}
```

Resume by `$NEW_SESSION_ID` (not name) to avoid any chance of name collision. `-Window current` maps to `wt -w 0`, which opens the new tab in the most-recently-used Windows Terminal window — i.e., next to the current Copilot session.

#### Step 4e — Minimal success report (replaces Step 3 output)

When the launch succeeds, the only message back to the user should be the new session ID and a confirmation that the terminal is being launched:

```
✅ Branched session: <NEW_SESSION_ID>
🚀 Launching it in a new Windows Terminal tab in this window...
```

Do not echo the resume commands, branch listing instructions, or worktree resume hints in this mode.

### 5. Truncation (Only If Requested)

If user says "branch from N turns ago", truncate events.jsonl to remove the last N turns:

#### Bash

```bash
"$PYTHON_BIN" -c "
import json, sys

turns_back = int(sys.argv[1])
lines = open('$NEW_SESSION/events.jsonl').readlines()
events = [json.loads(l.strip()) for l in lines]

# Find user.message events (each = 1 turn)
user_msgs = [(i, e) for i, e in enumerate(events) if e['type'] == 'user.message']
if turns_back >= len(user_msgs):
    print('Error: only', len(user_msgs), 'turns exist')
    sys.exit(1)

# Cut at the Nth-from-last user message
cut_idx = user_msgs[-turns_back][0]
events = events[:cut_idx]

with open('$NEW_SESSION/events.jsonl', 'w') as f:
    for e in events:
        f.write(json.dumps(e, separators=(',', ':')) + '\n')
print(f'Truncated to {len(events)} events (removed last {turns_back} turns)')
" N
```

#### PowerShell

```powershell
$truncateScript = @'
import json
import sys
from pathlib import Path

turns_back = int(sys.argv[1])
session_dir = Path(sys.argv[2])
events_file = session_dir / "events.jsonl"

events = [json.loads(line) for line in events_file.read_text(encoding="utf-8").splitlines() if line.strip()]
user_msgs = [(index, event) for index, event in enumerate(events) if event.get("type") == "user.message"]
if turns_back >= len(user_msgs):
    print(f"Error: only {len(user_msgs)} turns exist")
    sys.exit(1)

cut_idx = user_msgs[-turns_back][0]
events = events[:cut_idx]
events_file.write_text(
    "".join(json.dumps(event, separators=(",", ":")) + "\n" for event in events),
    encoding="utf-8",
)
print(f"Truncated to {len(events)} events (removed last {turns_back} turns)")
'@

$truncateScript | & $PYTHON_BIN - N $NEW_SESSION
```

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
