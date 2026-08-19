---
name: clear-workplace-writing
description: Write and revise clear workplace prose for engineering teams and engineering, product, and executive leadership. Use for technical explanations, design and architecture documents, proposals, decision records, incident and status updates, strategy memos, executive summaries, emails, PR descriptions, and other professional writing where readers need to understand an idea, trust the reasoning, or act on it. Adapt information structure to engineering, leadership, or mixed audiences while preserving technical precision, facts, uncertainty, and the writer's intended meaning.
---

# Clear Workplace Writing

Write so the intended reader can understand the important idea, trust the reasoning behind it, and know what to do with it while spending as little unnecessary effort as possible.

Do not optimize for brevity by itself. Optimize for reader effort, precision, and usefulness.

## Classify before writing

Infer two dimensions from the request. Do not ask unless the ambiguity would materially change the result.

**Audience**
- `engineering`: engineers or technical collaborators who need mechanism, constraints, correctness, and implementation consequences.
- `leadership`: engineering, product, or executive leaders who need significance, evidence, decisions, risks, and asks.
- `mixed`: both. Lead with the leadership-level conclusion, then progressively disclose the technical reasoning.

**Purpose**
- `explain`: build an accurate mental model.
- `propose`: recommend a change and defend the tradeoff.
- `decide`: make options, criteria, and recommendation easy to evaluate.
- `report-status`: communicate outcome, movement, risk, and next action.
- `report-incident`: communicate impact, cause, mitigation, and remaining risk.
- `instruct`: help a reader perform a task safely and correctly.
- `persuade`: change a belief or priority using explicit reasoning and evidence.

Load [engineering-writing.md](references/engineering-writing.md) for engineering audiences, [leadership-writing.md](references/leadership-writing.md) for leadership audiences, and both for mixed audiences. Load [structure-and-reasoning.md](references/structure-and-reasoning.md) when organizing a substantial document, proposal, decision, or explanation.

## Core principles

Apply these principles to all prose.

1. **Answer the reader's first question early.** Put the governing point, result, recommendation, or problem near the beginning. Do not make readers reenact the investigation before learning what it found.
2. **Organize by reader need, not discovery chronology.** Group evidence under the claim it supports. Preserve chronology only when sequence is itself important.
3. **Expose agency and action.** Make clear who or what does what. Prefer active voice when it clarifies agency. Use passive voice when the actor is unknown, irrelevant, intentionally omitted, or when the object is the established topic.
4. **Prefer concrete claims.** Replace abstractions with mechanisms, examples, measurements, named components, or observable behavior when available.
5. **Separate epistemic categories.** Distinguish observed fact, inference, assumption, recommendation, prediction, and uncertainty. Do not let a confident sentence blur the boundary.
6. **Expose the causal chain.** When one condition leads to another, state the mechanism or reasoning that connects them. A sequence of facts is not automatically an explanation.
7. **Preserve precise terminology.** Keep technical terms that carry real distinctions. Define unfamiliar terms when the audience may not know them. Never simplify a term into something less accurate merely to sound plain.
8. **Use one name for one concept.** Do not rotate synonyms for variety when they refer to the same system, component, metric, or idea.
9. **Control information flow.** Start sentences and paragraphs from context the reader already has, then introduce new information. Put important new information where it receives natural emphasis, often near the end of the sentence.
10. **Give each paragraph a job.** Open with the paragraph's controlling idea when practical; use the rest to support, qualify, or apply it.
11. **Cut words that do no work.** Remove ceremony, repeated conclusions, inflated adjectives, empty intensifiers, and transitions that add no relationship. Keep detail that reduces ambiguity or supports a decision.
12. **State relationships explicitly.** Use plain connectors such as `because`, `therefore`, `however`, `for example`, and `in contrast` when the logical relationship would otherwise be implicit.
13. **Keep evidence attached to the claim it supports.** Put metrics in context: baseline, comparison, time window, population, and important caveats.
14. **Prefer direct statements to rhetorical staging.** Avoid canned preambles, fake questions, summary paragraphs that merely repeat the preceding section, and generic claims that something is "important" without saying why.
15. **Preserve useful voice.** Clarity does not require sterile prose. Keep rhythm, humor, emphasis, and idiom when they help the reader and do not obscure meaning.
16. **Break a rule when the rule harms the sentence.** The principles exist to improve comprehension and judgment, not to produce mechanically compliant prose.

## Write or revise

When writing from scratch:
1. Identify the reader's likely question or decision.
2. Write the governing point in one or two sentences.
3. Arrange supporting claims in the order the reader needs them.
4. Add only the technical detail, evidence, and context needed to make those claims trustworthy and actionable.
5. Apply the audience-specific reference.

When revising existing prose:
1. Preserve facts, commitments, uncertainty, technical distinctions, and intentional tone.
2. Identify the actual governing point. Move it earlier if the draft buries it.
3. Reorder paragraphs before polishing sentences. Structural problems rarely yield to copyediting.
4. Repair agency, causality, terminology, information flow, and unnecessary abstraction.
5. Cut repetition and ceremony last. Do not shorten away evidence or reasoning.

Do not invent evidence, certainty, decisions, owners, deadlines, or implications that the source does not support.

## Choose structure from purpose

Use [structure-and-reasoning.md](references/structure-and-reasoning.md) for detailed patterns. Default shapes:

- `explain`: governing idea -> mental model -> mechanism -> example -> limits or edge cases.
- `propose`: problem -> recommendation -> why it works -> tradeoffs -> risks -> validation or next step.
- `decide`: recommendation -> decision criteria -> options and consequences -> evidence -> unresolved uncertainty.
- `report-status`: current state -> what changed -> impact -> risk/blocker -> next action or ask.
- `report-incident`: impact -> current state -> cause and evidence -> mitigation -> remaining risk -> follow-up.
- `instruct`: prerequisite/condition -> action -> expected result -> exception or recovery.
- `persuade`: claim -> reasons -> evidence -> strongest objection -> consequence or requested action.

Treat these as defaults, not templates to fill mechanically.

## Final audit

Before returning substantial prose, perform one silent revision pass using [revision-checklist.md](references/revision-checklist.md). Check especially:

- Can the intended reader identify the main point without reading the whole document?
- Is technical detail attached to a decision, claim, mechanism, or risk?
- Are facts, inference, and recommendation distinguishable?
- Does each paragraph advance the reader's understanding?
- Did the revision preserve important nuance rather than merely reduce word count?

For examples of the desired transformations, load [examples.md](references/examples.md). For the intellectual provenance and limits of these rules, load [source-notes.md](references/source-notes.md).