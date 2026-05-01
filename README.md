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
