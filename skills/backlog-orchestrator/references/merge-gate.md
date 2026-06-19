# Merge gate (phase 4)

Runs when an implementer sends `merge-ready`. It decides: **squash-merge now**, or **route to human
review**. It is the only place the orchestrator commits a merge.

## Short-circuit: human-disposition issues

If the issue's `merge_disposition == human`, **skip the subagent entirely**. This issue was triaged to
always get human review before merge. Outcome = `human-review`; send `human-review-pending` (reason:
"triaged human-review-before-merge") so the implementer holds the PR mergeable until the builder merges;
record nothing as a defect — this is by design. (Stand-down comes later, when the implementer reports
`merged`.) **Still harvest deferred work:** even though you skip the subagent, read the field report's
"Deferred / carry-forward work" section and record each item into the `deferred` table (status `open`) —
deferred harvest is unconditional (see "harvest DEFERRED work" below + reporting.md).

Otherwise (`merge_disposition == auto`), run the last-line review below.

## The last-line review subagent

This is **not** a correctness review. PAW Review and the implementer own correctness. This review asks
one question: **does the PR silently encode a decision the human builder should own?** It is the
filtered, plain-language form of the "high-spread value-fork" idea — surface forks where the builder's
*preference / direction / taste* (not correctness) should pick the answer.

Launch it with the `task` tool: `agent_type: general-purpose`, `model: claude-opus-4.8`,
`reasoning_effort: high`. Give it only the issue, the PR pointer, the two dials, and the charter; it
discovers the diff and repo conventions itself.

### Charter (fill `<repo>`, `<pr>`, `<issue>`, `<care_knob>`, `<posture>` and pass as the prompt)

```text
You are a last-line merge reviewer for an autonomous issue-fixing pipeline. A PR has already passed its
correctness review (PAW Review) and is merge-ready. You are NOT doing a correctness code review — do not
hunt for bugs, style, or missing tests; that is already owned by other agents. Your one job: decide
whether this PR silently encodes a decision the HUMAN BUILDER should own, in which case it must go to
human review instead of being auto-merged.

Repo: <repo>   PR: #<pr>   Issue: #<issue>   Dials: care=<care_knob>, posture=<posture>

Read the issue, the full PR diff, the implementer's **field report**, and whatever repo conventions/docs
you need yourself:
  gh issue view <issue> --repo <repo> --json title,body,comments
  gh pr view <pr> --repo <repo> --json title,body,headRefName,baseRefName,additions,deletions
  gh pr diff <pr> --repo <repo>

The implementer posts a **"Field report"** comment on the issue at merge-ready: its self-disclosed Outcome
(`Closes` vs `Refs`), key decisions/pivots, **preference debt**, deferred work, and risks. Use it as a
strong prior — it often names the forks for you — but verify against the diff and stay skeptical (it is an
interested party's self-report; the implementer may not see a fork it resolved unconsciously). A field
report that lands `Refs #` instead of `Closes #`, or that flags preference debt / deferred scope, is a
direct human-floor signal.

How to think:

1. Find the consequential decisions the PR encodes — choices that, made differently, send the code or
   product down a different road. Ignore forced moves (only one correct way) and trivially reversible
   details.

2. For each such decision, ask two SEPARATE questions:
   a. How far apart are the futures under the legitimate alternatives? Judge divergence along whichever
      apply: how hard to undo later; whether it locks in an architecture or a public/contract surface;
      whether it changes user-visible behavior; whether it forecloses future options; how expensive to
      flip AFTER merge; how much other code now depends on it.
   b. Is the right choice a matter of taste / product direction / the builder's vision — or of
      correctness? If one option is simply correct, it is NOT a preference fork; let it merge.

3. A decision needs the human when the futures diverge materially AND the right pick depends on the
   builder's preference, not correctness. Wider divergence + harder to reverse after merge => needs the
   human more.

4. Some forks are already settled — by the issue text, a documented repo convention, or an obvious
   project norm. A settled fork does NOT need the human; note it settled and move on. Do not invent a
   preference conflict the repo already answers. Standing norm for THIS builder: fixing a pre-existing
   broken thing (failing CI, build break, obvious bug), especially low-risk, even if it expands the PR's
   scope, is SETTLED — if it is broke, fix it; do NOT route that to human on scope-expansion grounds.

5. Stronger signal — constitution: did the PR have to INVENT the goal (vague issue, implementer decided
   what "done" means), REDEFINE the scope/meaning, land with `Refs #` instead of `Closes #`, or flag
   that the issue needs amendment? That is the builder's call — route to human regardless of how
   reversible the code is.

6. Calibrate with the dials: posture=craft => project futures far (more forks matter); posture=prototype
   => short horizon (only big, hard-to-reverse forks matter). When you are NOT confident the spread is
   low, lean toward surfacing — wrongly asking wastes a little time; wrongly staying silent ships a
   direction the builder never chose.

Do NOT try to guess which option the builder would prefer; that is theirs. You only detect that a fork
exists and how far it diverges, and you may offer a recommendation.

If, despite not doing a correctness review, you notice something that should plainly stop an auto-merge
(an obvious safety/security/data-loss risk, or the PR clearly does not do what the issue asked), set
human-review and say so in NOTES.

**Also harvest DEFERRED work (mandatory — separate from the fork question).** While you have the field
report and the full diff open, enumerate every piece of carry-forward / deferred work, so nothing slips
into limbo. Two sources: (a) the field report's "Deferred / carry-forward work" section; (b) the **diff
itself** — `TODO`/`FIXME`/`XXX`/`HACK` markers, "for now"/"out of scope"/"future"/"follow-up"/"deferred"
comments, stubbed or partial code paths, and acceptance-criteria the PR only partially meets. List each as
a self-contained item (one line: what + where + why deferred) — the orchestrator records these and drives
each to a disposition; you are NOT deciding the disposition, just ensuring the item is captured.

Output EXACTLY this structure:
VERDICT: clear | preference-debt | human-review
CONFIDENCE: high | medium | low   (confidence you have NOT missed a decisive fork)
FORKS: for each fork — one-line description; which axes diverge and how far; the legitimate options;
  your recommendation (labeled as a recommendation, not the answer); what you cannot see about the
  builder's intent that bears on it.
CONSTITUTION: yes/no + why
DEFERRED: a bullet per carry-forward item (field-report items + anything you found in the diff); each
  self-contained (what + where + why deferred). Write "none" only if you genuinely found none.
NOTES: anything else the orchestrator should record for the human.
```

**The orchestrator records every `DEFERRED` item** into the `deferred` table (reporting.md) with status
`open` — even on a `clear` auto-merge. Deferred harvest is unconditional; it does not depend on the
verdict.

## Orchestrator decision logic (you own the call; the subagent has voice)

Map the subagent's `VERDICT` (+ `CONFIDENCE`, `CONSTITUTION`) to an outcome using the issue's
`care_knob`. The subagent advises; you decide within the autonomy the triage configured; genuinely
decisive forks go to the human.

| Subagent result | `hard-stop-only` | `balanced` | `fail-toward-surfacing` |
|---|---|---|---|
| `CONSTITUTION: yes` | human | human | human |
| `human-review` | human | human | human |
| `preference-debt` | **merge + debt note** | merge + debt note, but **human if costly to reverse post-merge** | **human** |
| `clear` + CONFIDENCE high | merge | merge | merge |
| `clear` + CONFIDENCE low/medium | merge + debt note | merge + debt note | **human** |

"Costly to reverse post-merge" = the subagent flagged the fork as hard to flip once squash-merged and
the branch is deleted; when in doubt at `balanced`, treat low-confidence as costly.

- **merge** → squash-merge, verify closure, stand down merged (see below).
- **merge + debt note** → squash-merge, **and record the fork(s) as preference debt in the ledger**
  ([reporting.md](reporting.md)) with the subagent's options + recommendation, so the status/final
  report bubbles it up ("I chose X; flip it if you care"). Stand down merged.
- **human** → do not merge; record the well-lit bet (forks/options/recommendation/what-it-can't-see)
  and the reason in the ledger; send **`human-review-pending`** to the implementer (and reviewer) so they
  **hold** — the implementer keeps the PR mergeable until the builder merges — then advance. Do **not**
  send a stand-down now; you will send `stand-down-merged` later when the implementer reports `merged`
  (or `stand-down-human` if the builder abandons the PR).

## Merge mechanics

Use the gh account per the user's Copilot instructions (personal vs work for the target repo).

```powershell
gh pr merge <pr> --repo <repo> --squash --delete-branch
# Verify the issue closed (squash "Closes #n" auto-closes only on the default branch):
gh issue view <issue> --repo <repo> --json state
# If still open and the PR used Closes, close it:
gh issue close <issue> --repo <repo> --reason completed
```

Then send `stand-down-merged` to the implementer (reply in the `merge-ready` thread) and to the
reviewer address if a reviewer existed. Update `issues.status='merged'`, `pr_number`, `outcome_note`.

## What this gate is and is not

- It **is** a preference / human-floor gate: it protects the builder's right to own direction, and it
  audits the implementer's self-reported "ready" (an interested party's claim).
- It is **not** a second correctness pass. If it finds itself deep in bug-hunting, it has drifted —
  re-anchor on "should a human own a decision here?"
