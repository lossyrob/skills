# Triage (phase 2)

Interactive, with the user. Output is the **run manifest**: the issue list with a size and a complete
config per issue. Persist it so phase 3 can execute without re-asking.

## Step 1 — Intake

Pull candidate issues and present them for selection. Default to open, unassigned issues; let the user
narrow by label/milestone/text.

```bash
gh issue list --repo <owner/repo> --state open --limit 100 \
  --json number,title,labels,milestone,updatedAt
```

Show a compact table (number, title, labels). Ask the user which issues to include and in what order
(order matters — the run is sequential). The user may also paste explicit issue numbers.

## Step 2 — Size each issue S / M / L

S/M/L is the **operating point** (capability × stakes × attention), not just effort. It sets the
*defaults* for everything below. Propose a size per issue from the issue text and let the user adjust.

## Step 3 — Configure per tier (then override per issue)

For each issue, resolve these dimensions. Start from the tier default, then take per-issue overrides.
The single most important override the user flagged: the **care knob is independent of size** — a Large
issue can be low-care ("PAW Review is enough; my taste won't change the answer").

| Dimension | Values | What it controls |
|---|---|---|
| `reviewer_enabled` | true / false | Whether a PAW Review worker is launched alongside the implementer. |
| `impl_config` | a PAW config block | The implementer's PAW workflow config (see below). |
| `review_config` | a PAW Review config block | The reviewer's PAW Review strategy (ignored if `reviewer_enabled=false`). |
| `merge_disposition` | `auto` / `human` | `auto` = eligible for auto-merge **subject to** the last-line review. `human` = always human review before merge (skip the subagent; send `human-review-pending` once merge-ready, then `stand-down-merged` after the builder merges). |
| `care_knob` | `hard-stop-only` / `balanced` / `fail-toward-surfacing` | How aggressively the merge gate surfaces preference forks (see merge-gate.md). |
| `posture` | `prototype` / `balanced` / `craft` | Projection horizon for "how much does this fork matter": prototype = short, craft = long. |
| `base_branch` | branch name (optional) | If the issue targets a non-default base. |
| `pr_title_format` | title template | The exact PR title shape after substituting `{title}`, `{issue}`, and optional `{workstream}` tokens. |

### Suggested tier defaults (confirm/edit with the user)

| | reviewer | merge_disposition | care_knob | posture |
|---|---|---|---|---|
| **S** | off (or on for risky small) | auto | hard-stop-only | prototype/balanced |
| **M** | on | auto | balanced | balanced |
| **L** | on | auto (or human) | fail-toward-surfacing* | craft |

\* Per the user: L often warrants `fail-toward-surfacing`, but offer to drop to `balanced` or
`hard-stop-only` when the Large work is "straightforward / correctness-only" and the user's preference
won't drive the answer.

### PAW config blocks

Reuse the streamliner-style PAW config the user already runs with. A reasonable implementer default
(adjust per tier) mirrors `paw-lite`:

```text
Workflow Identity: paw-lite
Planning Docs Review: enabled | Planning Review Mode: society-of-thought | parallel
Planning Review Specialists: general-reviewer | Models: general-reviewer:claude-opus-high
Final Agent Review: enabled | Final Review Mode: society-of-thought | parallel
Review Policy: final-pr-only | Artifact Lifecycle: commit-and-clean
```

Reviewer default (when `reviewer_enabled`): PAW Review workflow, SoT parallel with all specialists +
a rubber-duck subagent, SoT specialists pinned to `claude-opus-high`. The user may simplify for S/M.

Capture each block as free text; it is injected verbatim into the worker prompt. The model ids above
are illustrative — substitute your current opus-high pins. Keep tiers consistent unless the user
customizes a specific issue.

### PR title format

Choose a run-wide default during initialization, then allow tier or per-issue overrides. Recommend:

```text
{title} (#{issue})
```

Supported tokens are:

| Token | Value |
|---|---|
| `{title}` | The GitHub issue title. |
| `{issue}` | The issue number without `#`. |
| `{workstream}` | The internal `<runid>-<n>` workstream id. Include this token only when the user wants an internal tracking id in PR titles. |

Literal text is preserved, so `[{workstream}] {title} (#{issue})` restores the previous title shape.
Before locking the manifest, reject unknown `{...}` tokens, substitute sample values, and require a
non-empty result. Persist the resolved format on every issue row; workers must not infer a format from
the workstream id.

## Step 4 — Persist the run manifest

Persist the runtime selected by [runtime-selection.md](runtime-selection.md). Capture only that mode's
transport fields:

- **App:** current `project_id` and `project_session_id`. If the target repository belongs to another
  configured project, resolve its exact id with `list_projects`; do not create a project without the
  user's approval.
- **CLI:** local `repo_path`, one shared `telex_backend`, and `terminal_app` (`auto`, `terminal`, or
  explicitly selected `iterm2` on macOS). Before iTerm2, disclose the one-time Automation consent.

Create the run tables (the shared `todos` table is used separately for lifecycle progress):

```sql
CREATE TABLE IF NOT EXISTS run_meta (key TEXT PRIMARY KEY, value TEXT);
-- common keys: runid, runtime_mode (app|cli), repo, base_branch_default,
--              pr_title_format_default, gh_note, created_at
-- app keys: project_id, orchestrator_session_id
-- cli keys: repo_path, telex_backend, terminal_app, orchestrator_address

CREATE TABLE IF NOT EXISTS issues (
  issue_number     INTEGER PRIMARY KEY,
  position         INTEGER,           -- execution order
  title            TEXT,
  size             TEXT,              -- S | M | L
  reviewer_enabled INTEGER,           -- 0 | 1
  impl_config      TEXT,
  review_config    TEXT,
  merge_disposition TEXT,             -- auto | human
  care_knob        TEXT,              -- hard-stop-only | balanced | fail-toward-surfacing
  posture          TEXT,              -- prototype | balanced | craft
  base_branch      TEXT,
  pr_title_format  TEXT NOT NULL,     -- resolved template; default: {title} (#{issue})
  status           TEXT DEFAULT 'pending',  -- pending|running|merged|human-review|blocked
  pr_number        INTEGER,
  -- App mode only:
  implementer_session_id TEXT,
  reviewer_session_id    TEXT,
  -- CLI mode only:
  implementer_address    TEXT,
  reviewer_address       TEXT,
  outcome_note     TEXT
);
```

Store `{title} (#{issue})` as `run_meta.pr_title_format_default` unless the user chooses another
run-wide default. Insert one row per selected issue, in execution order, with its fully resolved
`pr_title_format`. Also add a lifecycle `todo` per issue (gerund title, e.g. "Driving issue #123 to
terminal") so progress is visible in `todo_status`.

When resuming a manifest created before `pr_title_format` existed, inspect `PRAGMA table_info(issues)`.
If the column is absent, add it and backfill before dispatching another worker:

```sql
ALTER TABLE issues ADD COLUMN pr_title_format TEXT;
INSERT OR IGNORE INTO run_meta (key, value)
VALUES ('pr_title_format_default', '{title} (#{issue})');
UPDATE issues
SET pr_title_format = (
  SELECT value FROM run_meta WHERE key = 'pr_title_format_default'
)
WHERE pr_title_format IS NULL;
```

This keeps existing app and CLI runs resumable without restoring the opaque workstream prefix.

## Step 5 — Confirm and lock

Echo the full manifest back to the user as a table (issue, size, reviewer, disposition, care, posture,
PR title format). Get a clear go-ahead before phase 3. Note explicitly which issues are
`merge_disposition=human` (they will never auto-merge) so the user is not surprised at the end.
