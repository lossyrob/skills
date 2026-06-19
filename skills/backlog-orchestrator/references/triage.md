# Triage (phase 2)

Interactive, with the user. Output is the **run manifest**: the issue list with a size and a complete
config per issue. Persist it so phase 3 can execute without re-asking.

## Step 1 — Intake

Pull candidate issues and present them for selection. Default to open, unassigned issues; let the user
narrow by label/milestone/text.

```powershell
gh issue list --repo <owner/repo> --state open --limit 100 `
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

## Step 4 — Persist the run manifest

Create the run tables (the shared `todos` table is used separately for lifecycle progress):

```sql
CREATE TABLE IF NOT EXISTS run_meta (key TEXT PRIMARY KEY, value TEXT);
-- run_meta keys: runid, repo, repo_path, telex_backend, base_branch_default, gh_note, created_at
-- telex_backend: the telex backend name EVERY session in this run pins via --backend (e.g. `local`
--   sqlite, or a named Postgres like `pg-rde-telex`). Choose it at triage; never rely on the telex
--   default backend (the user can change the default mid-run and split the run across stores). It is
--   injected into every worker prompt as {{telexBackend}} and used on all orchestrator telex commands.

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
  status           TEXT DEFAULT 'pending',  -- pending|running|merged|human-review|blocked
  pr_number        INTEGER,
  outcome_note     TEXT
);
```

Insert one row per selected issue, in execution order. Also add a lifecycle `todo` per issue (gerund
title, e.g. "Driving issue #123 to terminal") so progress is visible in `todo_status`.

## Step 5 — Confirm and lock

Echo the full manifest back to the user as a table (issue, size, reviewer, disposition, care, posture).
Get a clear go-ahead before phase 3. Note explicitly which issues are `merge_disposition=human` (they
will never auto-merge) so the user is not surprised at the end.
