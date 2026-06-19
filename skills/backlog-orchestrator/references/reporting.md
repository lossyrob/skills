# Reporting

Two layers: each **implementer** posts a **field report** on its issue (durable, on GitHub); the
**orchestrator** keeps a **run ledger** (session SQL) and synthesizes a **status / final report** on
demand. The user cares most about: **interesting pivots/choices, preference debt, decisions not to
auto-merge, and deferred work/learnings** — foreground these.

## The run ledger (orchestrator, session SQL)

```sql
CREATE TABLE IF NOT EXISTS ledger (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  issue_number INTEGER,
  ts           TEXT DEFAULT (datetime('now')),
  kind         TEXT,   -- preference-debt | no-auto-merge | blocker | pivot | deferred | subagent-verdict | merged | process-feedback | note
  detail       TEXT
);
```

Record an entry at each decision point:
- **Merge gate** → `subagent-verdict` (the full VERDICT/CONFIDENCE/FORKS/NOTES), plus `preference-debt`
  for each fork carried as debt on an auto-merge, or `no-auto-merge` with the well-lit bet when routed
  to human.
- **Lifecycle** → `blocker` when a worker reports `blocked`; `merged` on a successful merge.
- When you read a worker's field report (below), copy any **pivots** and **deferred** items into the
  ledger so the final report does not depend on re-reading every issue.
- On `process-feedback` from a worker, log it as `kind='process-feedback'` — these are about the
  **process/skill itself**, not the code.

### Process feedback → skill improvement

Workers send a `process-feedback` telex at finish describing friction with the telex instructions, the
prompt templates, or the config. Collect them across the run. At end of run — and whenever you notice
friction yourself — synthesize the actionable items and **improve the orchestrator skill**
(`~/.copilot/skills/backlog-orchestrator`): edit the templates, telex-protocol, triage, or this file so
the next run is smoother. Include a short "skill improvements absorbed / proposed" section in the final
report.

## Implementer field report (on the issue)

The implementer posts this as an issue comment at **merge-ready** — *before* it signals the orchestrator
— so the report is a first-class input to the merge gate and to the builder's review, not a post-hoc
artifact. It is **updated with a brief addendum at stand-down** if anything changed afterward (e.g.
post-routing conflict/CI repairs during the human-review hold). It follows the streamliner/paw-docs-guidance
field-report shape. Canonical fields (the implementer template embeds this list):

- **Outcome:** completed | partial | blocked; and whether the PR used `Closes #` or `Refs #` and why.
- **Key decisions & pivots:** notable choices, especially divergences from the original design or issue.
- **Preference debt:** any fork the implementer resolved that the builder might want to revisit.
- **Assumptions:** that held, failed, or changed.
- **Context gaps:** missing/stale/misleading context discovered (issue, code, conventions).
- **Deferred / carry-forward work:** anything intentionally not done, scope it captured for later.
- **Risks / shortcuts / known defects** left behind.
- **For orchestrator / for builder:** anything needing reconciliation or the builder's attention.

The orchestrator's merge-gate preference-debt notes and the implementer's field-report preference-debt
are complementary: the gate catches forks the implementer did not flag; the field report catches the
implementer's own self-aware debt. The status report merges both.

## Deferred-work tracking (harvest → disposition → triage)

Deferred work needs the **same forcing function as preference forks** — otherwise carry-forward items
silently fall through. Track it as a first-class entity, not a loose list.

**Table (session SQL):**
```sql
CREATE TABLE IF NOT EXISTS deferred (
  key          TEXT PRIMARY KEY,        -- e.g. 'D4-A'
  issue_number INTEGER,                 -- source issue
  description  TEXT,                     -- self-contained: what + where + why deferred
  status       TEXT DEFAULT 'open',      -- open | filed | folded | skipped | done | moot
  disposition  TEXT                      -- issue ref / fold target / skip reason
);
```

1. **Harvest (mandatory, at the gate).** When you process `merge-ready`, the merge-gate subagent emits a
   `DEFERRED:` list (field-report items + diff markers — TODO/FIXME/"for now"/"out of scope"/stubbed
   paths). Insert **every** item as a `deferred` row with status `open`. This is **unconditional** — do it
   even on a `clear` auto-merge, and even for human-disposition issues that skip the subagent (harvest the
   field report's Deferred section yourself in that case). Missing this harvest is the #1 way deferred work
   is lost.
2. **Disposition (every item reaches terminal).** No item stays `open`. Terminal states: `filed`
   (→issue#), `folded` (→ another issue/PR, e.g. a TUI/observability PR), `skipped` (+explicit reason),
   `done` (actually handled), `moot` (superseded). Triage **with the builder** (their standing preference:
   some get closed immediately) — recommend a disposition per item, get their call, then file the `filed`
   ones and record dispositions.
3. **Run-completion gate.** The run is **not complete** until `SELECT COUNT(*) FROM deferred WHERE
   status='open'` returns **0**. Before declaring the run done, run the triage routine on any remaining
   opens. The final report's Deferred section is this table grouped by disposition — not a loose list.
4. **On-demand triage routine.** When asked (or at run-end): `SELECT * FROM deferred WHERE status='open'`,
   present each with a recommended disposition, get the builder's calls, create the filed issues
   (`Refs #<source>` + a one-line "Deferred from PR #<n>" provenance), and update each row.

## Status / final report (on demand)

When the user returns and asks for status (or at end of run), produce a report that **leads with signal**,
not raw progress. Build it from `issues`, `ledger`, `deferred`, and — for depth — the field reports.

Suggested shape:

1. **Headline:** N issues — X merged, Y pending human review, Z blocked, remainder pending.
2. **Needs your attention now:**
   - Issues **pending human review** — for each: PR link, the fork(s) and the well-lit bet (options,
     the subagent's recommendation, what it couldn't see), and why it did not auto-merge.
   - **Blockers** — for each: the reason and what you did (moved on / awaiting user).
3. **Preference debt on merged PRs:** the "I chose X; flip it if you care" items, per issue, with PR
   links — so the user can still flip them post-merge.
4. **Interesting pivots / choices:** from the field reports — divergences from the original
   design/issue worth knowing.
5. **Deferred / carry-forward work:** the `deferred` table grouped by disposition (filed→issue#,
   folded, skipped+reason, moot, done). Flag any still `open` as needing triage **now** (the run is not
   complete while any remain open).
6. **Learnings / context gaps:** recurring stale-context or assumption failures across issues.

To pull the field reports for synthesis:

```powershell
gh issue view <issue> --repo <repo> --json comments `
  --jq '.comments[] | select(.body | test("Field report|Outcome:")) | .body'
```

Answer follow-up questions ("what did #123 decide?", "what's still deferred?") by querying the ledger
and the specific field report. Keep the report tight; the user wants the pivots, the debt, the deferred
work, and the learnings — not a blow-by-blow.
