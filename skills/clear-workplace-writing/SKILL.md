---
name: clear-workplace-writing
description: Write, revise, or review clear workplace prose for engineers and leadership. Use for documents, proposals, reports, memos, status and incident updates, executive narratives, emails, PR descriptions, and other professional writing. Preserves facts, technical precision, uncertainty, and the author's voice while improving structure, clarity, and usefulness.
---

# Clear Workplace Writing

Write so the intended reader can understand the important idea, trust the
reasoning behind it, and know what to do with it without unnecessary effort.

Use [core-practices.md](core-practices.md) as the practical authority. It
synthesizes the durable guidance in the bundled public-domain sources and the
project's modern workplace-writing preferences.

## Choose an execution path

### Direct

Write or revise in the current context when the material is short, supplied
inline, or central to the current task.

1. Read `core-practices.md`.
2. Identify the audience, purpose, intended response, and facts the draft can
   support.
3. Draft or revise in the order given by the guide.
4. Perform the guide's final Keep and Cut passes.

Do not create files or delegate a short passage merely to follow a workflow.
Making no changes is a valid result when the passage already meets the guide.

### Contained editor

Use one strong general-purpose subagent when a document is large enough to
crowd the main context, when writing is a side task in a context-heavy session,
or when the user asks for a contained review.

Prefer a file path over embedding a long document in the subagent prompt. Give
the editor:

- the source path and requested output path;
- the path to `core-practices.md`;
- the audience, purpose, requested response, and explicit user constraints;
- whether to revise, comment, or do both.

Require the editor to:

1. Read the source and `core-practices.md`.
2. Inventory material facts, numbers, dates, commitments, qualifications,
   technical terms, and open questions before editing.
3. Write a new revision rather than overwrite the source unless the user
   explicitly requests in-place editing.
4. Write a short review note recording structural changes, material deletions,
   unresolved ambiguities, and anything that could not be preserved.
5. Recheck the revision against the inventory.
6. Return only the output paths and a concise summary to the main agent.

Keep iterative, approval-per-change editing in the main context so the user can
control each revision.

### Multi-perspective review

Use multi-perspective review only when the user explicitly requests it or the
document is both consequential and structurally difficult. When the `council`
skill is available, use it instead of building a separate reviewer hierarchy.
Use these independent lenses:

1. structure, argument, and reader needs;
2. accuracy, evidence, and uncertainty;
3. sentence clarity, economy, emphasis, and voice.

Have one synthesis editor resolve the findings. Do not assign reviewers by
historical author; their advice overlaps too heavily.

## Source consultation

Historical sources explain, challenge, or deepen a practice. They do not
replace `core-practices.md`.

| Reference | Approximate cost | Consult when |
|---|---:|---|
| `references/elements-of-style-1918.md` | 17k tokens | A Strunk-specific pass or an exact rule is needed |
| `references/abbott-index.md` | 1.6k tokens | Locate an Abbott rule |
| `references/abbott-rules.md` | 17k tokens | Read only a rule identified by the index or a source tag |
| `references/spencer-excerpts.md` | 2k tokens | Examine a cited rationale or qualification |
| `references/sources.md` | small | Check provenance, editions, exclusions, or citation syntax |

Never load all historical references for a routine edit. Read the synthesis
first, then consult the smallest relevant source section. The source tags in
`core-practices.md` provide addresses.

## Invariants

No stylistic rule may silently change:

- a fact, number, date, name, or commitment;
- the strength or scope of a claim;
- uncertainty, risk, or an open question;
- a technical distinction;
- the author's intended meaning.

Do not invent evidence, certainty, decisions, owners, deadlines, objections, or
implications. If a requested style would compromise these invariants, preserve
the invariant and explain the conflict.

Explicit instructions in the current request govern style. Otherwise,
`core-practices.md` governs. Historical sources are persuasive context rather
than binding rules.
