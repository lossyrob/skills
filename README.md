# lossyrob-skills

Reusable [Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli) skills.

## Install

If you previously installed the plugin directly from the repository, uninstall
that copy first:

```bash
copilot plugin uninstall lossyrob-skills
```

Add this repo as a Copilot CLI plugin marketplace, then install the skills plugin
from it:

```bash
copilot plugin marketplace add lossyrob/skills
copilot plugin marketplace browse lossyrob-skills
copilot plugin install lossyrob-skills@lossyrob-skills
```

## Skills

### launch-copilot-terminal

Launch a new Windows Terminal tab running Copilot CLI with a requested title, tab color, and working directory. Supports a prompt-driven interactive session, an existing-session resume, and targeting either a separate window or the current Windows Terminal window. Useful for starting parallel Copilot sessions, focused worker windows, or opening a resumed session beside the current one.

**Trigger phrases:** "launch Copilot terminal", "open Copilot window", "start Copilot session", "spawn Copilot worker"

**Features:**
- Opens a Windows Terminal tab with a chosen title and tab color
- Two modes: **prompt mode** starts Copilot with `copilot -i <prompt>`; **resume mode** reattaches to an existing session with `copilot --resume <id-or-name>` (no prompt submitted)
- `-Window {new|current}` selects whether the tab opens in a separate window (`wt -w -1`, the default) or in the current Windows Terminal window (`wt -w 0`)
- Supports explicit working directories, extra Copilot CLI arguments, and prompt files
- Includes dry-run output for inspecting the generated launch command

**Requirements:** Windows, Windows Terminal (`wt.exe`), PowerShell 5.1+/7+, and Copilot CLI on `PATH`.

### loop

Repeatedly run a check command or script on a configurable interval until a condition is met, a timeout is reached, or an actionable exit code is returned. Useful for waiting on services, polling PR status, retrying commands, and watching CI/review/mergeability gates before continuing.

**Trigger phrases:** "loop", "wait until", "poll", "watch", "retry", "check every N minutes", "wait for CI", "wait for approval"

**Features:**
- Cross-platform runners for Bash (`scripts/loop.sh`) and PowerShell, where agent workflows default to detached `Start-LoopDetached.ps1` with attached `loop.ps1` reserved for short-lived/debug cases
- Fixed interval, timeout, max tries, exponential backoff, jitter, and stability windows
- Retry-vs-stop exit-code routing so the agent can fix actionable states and restart the loop
- Optional success action, acknowledgement command, retry hook, singleton lock, quiet mode, and dry-run output
- PowerShell persistent state files (`last-result.json`, `heartbeat.json`, immutable event files) plus detached launch/status helpers with PID start-time validation for durable agent coordination; detached runs require explicit status observation or handoff because they do not send tool completion notifications
- GitHub PR readiness helpers for approval, checks, merge conflicts, closed PRs, and merge race protection

**Requirements:** Bash for macOS/Linux/Git Bash workflows or PowerShell 5.1+/7+. GitHub PR polling requires `gh`.

### session-branch

Branch the current Copilot CLI session, creating a new session that inherits conversation history up to the current point while preserving the original session intact. Useful for experimentation or parallel development without losing your place.

**Trigger phrases:** "branch", "branch session", "fork session", "create a branch from here". Append "launch in terminal" or "open in a new tab" to open the branched session in a new Windows Terminal tab beside the current one (Windows only).

**Features:**
- Copies full session state (events, workspace config) into a temporary staging directory and atomically renames into place; failed branches never leave a half-branched session on disk
- YAML-aware `workspace.yaml` rewriter handles block-scalar names (`name: |-`, folded `>`, etc.) correctly — the original block body is fully replaced and the branch title is derived from the reconstructed content
- Post-rewrite validation refuses duplicate top-level keys and orphan indented lines, so corruption in the source is caught before the branched session is committed to disk
- Assigns each branch a unique Copilot CLI resume title like `Branch: <title> [<id>]` and tracks lineage via `branch_of` / `branch_note` in `workspace.yaml`
- Includes Bash and Windows PowerShell branching workflows; branch logic ships as `scripts/branch_session.py` with a `unittest` test suite
- Removes stale in-use locks from the branched session; resets checkpoints and rewind snapshots for a clean slate
- Optional "launch in terminal" mode (Windows-only) opens the branched session in a new Windows Terminal tab inside the current window via the [`launch-copilot-terminal`](#launch-copilot-terminal) helper
- Optional truncation ("branch from N turns ago") and optional git worktree integration

**Requirements:** Python 3. On Windows, the skill validates Python candidates and prefers the Python launcher (`py -3`) or a real `python.exe` before falling back to `python3`, avoiding unusable Windows Store app-execution aliases. The launch-in-terminal mode additionally requires Windows, Windows Terminal (`wt.exe`), and the `launch-copilot-terminal` skill.

### odt-convert

Convert ODT (OpenDocument Text) files to Markdown with full comment and embedded object extraction.

**Trigger phrases:** "convert odt", "extract odt comments", "odt to markdown", or when working with `.odt` files

**Features:**
- Document body conversion via `pandoc` with `--wrap=none`
- Threaded comment extraction with anchor text and reply grouping
- Inline image extraction (fixes pandoc `[]{.image}` placeholder failures)
- Visio diagram extraction (`.vsdx`) with PNG preview generation
- All media output to a `<name>-embedded/` subdirectory

**Requirements:** `pandoc`, Python 3. Optional: `olefile` (Visio), `libreoffice` (EMF→PNG).

## License

MIT
