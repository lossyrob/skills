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
- PowerShell persistent state files (`last-result.json`, `heartbeat.json`, immutable event files) plus detached launch/status/wait helpers with PID start-time validation; the quiet waiter lets the agent sleep until detached state becomes actionable or final and can be backgrounded in the host CLI while preserving automatic wakeup
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

### paw-pr-lifecycle

Operate PAW implementer and reviewer GitHub PR lifecycle loops on top of the `loop` skill: PR discovery for reviewers, review-response and merge-readiness sentries for implementers, marker-driven handoff between roles, and re-review requests after substantive post-approval changes. Opinionated for PAW workflow sessions and their `🐾 PAW …` comment/review markers.

**Trigger phrases:** "PAW PR lifecycle", "PAW implementer loop", "PAW reviewer loop", "watch this PR until merge", "wait for PAW approval", "PAW PR sentry"

**Features:**
- Mode-based: Implementation → Review Response → PR Sentry for the implementer; PR Discovery → Review → Follow-up Sentry for the reviewer
- Marker contract for the three `🐾 PAW …` events; a `+1` review may include non-blocking notes and the implementer is required to read the body before transitioning to PR Sentry
- Five canonical check scripts (`impl-review-response-check.ps1`, `impl-merge-sentry-check.ps1`, `review-pr-discovery-check.ps1`, `review-addressed-check.ps1`, plus the shared `github-loop-common.ps1`) with GitHub rate-limit/transient-error routing through the loop skill's retry/stop exit codes
- `Get-LoopScriptPaths.ps1` resolves the sibling `loop` skill automatically (checked-out repo → default plugin install → bare-skills install → recursive `~/.copilot` fallback)
- Multi-account `gh` support: the loop scripts assert the requested `<gh-user>` is authenticated and pin API calls to that account's token

**Requirements:** PowerShell 7+ on any OS, GitHub CLI authenticated against `github.com`, and the sibling [`loop`](#loop) skill (≥ 0.1.12).

### backlog-orchestrator

Drive a backlog of GitHub issues to PRs autonomously and sequentially. The loaded session becomes an orchestrator that triages issues into S/M/L tiers, spawns PAW implementer (and optional PAW Review) worker terminals that coordinate over [telex](https://github.com/lossyrob/telex) instead of GitHub-comment polling, gates each PR through a preference/human-floor merge review, and auto-merges or routes to human review.

**Trigger phrases:** "work through a backlog of issues autonomously", "run an autonomous issue-fixing pipeline", "orchestrate PAW sessions across many issues", "drive these issues to PRs"

**Features:**
- Four-phase model: telex station setup → interactive triage (S/M/L sizing + per-tier config) → sequential per-issue execution → merge gate + advance
- Spawns an implementer (paw-lite, loaded as a skill) and an optional reviewer (launched as the `PAW-Review` agent with autonomous review submission) in their own terminals via [`launch-copilot-terminal`](#launch-copilot-terminal); they run the review handshake over telex (review-ready → review-posted → re-review → `🐾 +1`), not GitHub-comment polling
- Last-line **merge gate**: an Opus subagent detects high-spread *preference forks* the builder should own (a filtered work-geometry lens, not a correctness re-review), tuned by a per-issue care-knob — auto-merges clear/low-spread PRs and routes preference-debt / constitution / human-floor PRs to human review
- **Deferred-work tracking**: every carry-forward item is harvested at the gate (field report + diff markers) and driven to a terminal disposition (filed / folded / skipped / done / moot) — the run is not complete while any item is open
- **Deferred human-review holds**: a PR routed to you stays live — the implementer's merge sentry keeps it mergeable (repairing CI/conflicts) until you merge, then reports back for stand-down
- Field reports on each issue + a run ledger; a final report bubbles up pivots, preference debt, no-auto-merge decisions, deferred work, and learnings, plus a `process-feedback` → skill-improvement loop
- Durable telex backend pinning so messages survive holder restarts and wake idle worker sessions

**Requirements:** Windows + Windows Terminal (for `launch-copilot-terminal`), Copilot CLI on `PATH`, [telex](https://github.com/lossyrob/telex) on `PATH`, GitHub CLI authenticated for the target repo, and the installed skills [`launch-copilot-terminal`](#launch-copilot-terminal), [`paw-pr-lifecycle`](#paw-pr-lifecycle), [`loop`](#loop), [`spar`](#spar), plus the PAW workflow skills (paw-lite / paw-review-workflow) and the `PAW-Review` custom agent.

### spar

Get a sharp second opinion from a different model before committing to a consequential decision. A pairing-style critique skill run as **sparring rounds**: it keeps the structure of pair programming (shared goal, two perspectives per decision, the driver holds the pen) but drops the ego-protecting hedging that turns review into a rubber stamp, since there is no human ego to protect between agents.

**Trigger phrases:** "pair", "spar", "rubber duck", "get a second opinion", "discuss amongst yourselves", "consult another model before committing"

**Features:**
- Gated, not ambient: open an episode only for decisions that are both consequential and uncertain (load-bearing design/contract, plan invalidation, non-trivial fork, boundary change, repeated failure) — never for routine coding or "review this diff"
- Cross-model by design: the pair runs as a different-model `rubber-duck` subagent (default Opus 4.8 when the driver is GPT-5.5, and vice versa); operators can pin a model
- Dialogic depth: gate the entrance, not the depth — run several short rounds while they keep resolving the same decision, with a context packet to offset the subagent's missing history
- Anti-sycophancy: the pair attacks assumptions and surfaces failure modes rather than validating; explicit closure (revise the plan or record why the critique does not apply)
- Two modes: **integrate** (fold the outcome in and proceed) or **brief-back** (bring the operator a brief of gaps and recommendations)
- Caller-customizable: prompts or operators can add domain triggers, pin a model, or force a mode

**Requirements:** Copilot CLI with the `task` (subagent) tool and a second model available for the pairing subagent. Uses the `rubber-duck` agent type when available and falls back to a `general-purpose` subagent with the sparring role in its prompt; if the named default pairing model is unavailable, any model different from the driver works.

## License

MIT
