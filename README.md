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

Launch a new Windows Terminal window running Copilot CLI with a requested title, tab color, working directory, and seeded interactive prompt. Useful for starting parallel Copilot sessions or focused worker windows from an existing session.

**Trigger phrases:** "launch Copilot terminal", "open Copilot window", "start Copilot session", "spawn Copilot worker"

**Features:**
- Opens a separate Windows Terminal window with a chosen title and tab color
- Starts Copilot CLI interactively with `copilot -i <prompt>`
- Supports explicit working directories, extra Copilot CLI arguments, and prompt files
- Includes dry-run output for inspecting the generated launch command

**Requirements:** Windows, Windows Terminal (`wt.exe`), PowerShell 5.1+/7+, and Copilot CLI on `PATH`.

### loop

Repeatedly run a check command or script on a configurable interval until a condition is met, a timeout is reached, or an actionable exit code is returned. Useful for waiting on services, polling PR status, retrying commands, and watching CI/review/mergeability gates before continuing.

**Trigger phrases:** "loop", "wait until", "poll", "watch", "retry", "check every N minutes", "wait for CI", "wait for approval"

**Features:**
- Cross-platform runners for Bash (`scripts/loop.sh`) and PowerShell (`scripts/loop.ps1`)
- Fixed interval, timeout, max tries, exponential backoff, jitter, and stability windows
- Retry-vs-stop exit-code routing so the agent can fix actionable states and restart the loop
- Optional success action, acknowledgement command, retry hook, singleton lock, quiet mode, and dry-run output
- GitHub PR readiness helpers for approval, checks, merge conflicts, closed PRs, and merge race protection

**Requirements:** Bash for macOS/Linux/Git Bash workflows or PowerShell 5.1+/7+. GitHub PR polling requires `gh`.

### session-branch

Branch the current Copilot CLI session, creating a new session that inherits conversation history up to the current point while preserving the original session intact. Useful for experimentation or parallel development without losing your place.

**Trigger phrases:** "branch", "branch session", "fork session", "create a branch from here"

**Features:**
- Copies full session state (events, workspace config)
- Assigns each branch a unique Copilot CLI resume title like `Branch: <title> [<id>]`
- Tracks lineage via `branch_of` / `branch_note` in `workspace.yaml`
- Removes stale in-use locks from the branched session
- Resets checkpoints and rewind snapshots for a clean slate
- Optional truncation ("branch from N turns ago")
- Optional git worktree integration

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
