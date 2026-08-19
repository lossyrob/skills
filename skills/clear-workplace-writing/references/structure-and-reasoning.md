# Structure and reasoning

Use structure to expose the logic of the material. A document should make its argument inspectable rather than merely pleasant to read.

## Governing idea first

For substantial workplace prose, identify the governing idea: the single claim, recommendation, result, or problem that gives the document its reason to exist.

Put that idea early unless suspense or chronology is genuinely part of the task. Workplace readers are usually deciding whether to understand, challenge, approve, prioritize, or act. Give them the object of that work.

## Group support under claims

Use a pyramid-shaped argument when useful:

1. governing claim or recommendation;
2. a small set of logically distinct supporting claims;
3. evidence, examples, and technical detail under the claim they support.

Each child should answer a natural question raised by its parent. Avoid sections that exist because information happened to be collected together.

Useful grouping tests:

- Are the items all reasons for the same claim?
- Are they mutually understandable categories rather than overlapping scraps?
- Does their order follow logic: causal, chronological, comparative, priority, or dependency?
- Would removing the heading make the relationship between paragraphs harder to see?

If the answers are weak, the structure probably is too.

## Causal explanations

Separate four things that prose often smears together:

- **observation:** what happened;
- **mechanism:** how it happened;
- **interpretation:** what the evidence suggests;
- **consequence:** why it matters or what follows.

Example:

> After the rollout, write latency increased 25% on shards above 80% utilization. The new compaction policy schedules more concurrent I/O on those shards, which saturates the storage queue. That mechanism explains why low-utilization shards did not regress. We should disable the policy above the utilization threshold while we test a concurrency cap.

The recommendation is credible because the causal chain is visible.

## Information flow inside sentences

Readers usually process sentences more easily when familiar context appears early and important new information appears later.

Weak:

> A 40% increase in lock waits was caused by the new reconciliation worker on large tenants.

Better when the worker is already the topic:

> On large tenants, the new reconciliation worker increased lock waits by 40%.

Better when lock waits are already the topic:

> Lock waits increased 40% on large tenants after the new reconciliation worker was enabled.

Choose the sentence subject based on what the surrounding paragraph is about, not from a universal active/passive rule.

## Purpose patterns

### Explain

Use: **governing idea -> mental model -> mechanism -> example -> limits**.

The mental model should make later detail easier to place. Do not front-load every exception.

### Propose

Use: **problem -> recommendation -> mechanism -> tradeoffs -> risks -> validation**.

The problem must be specific enough that the recommendation can be judged against it.

### Decide

Use: **recommendation -> criteria -> options -> evidence -> uncertainty**.

Name criteria before comparing options. Otherwise the preferred option can quietly define the rubric after the fact.

### Report status

Use: **state -> change -> consequence -> risk -> next action**.

Chronology belongs only where it explains the change.

### Report incident

Use: **impact -> current state -> cause/evidence -> mitigation -> remaining risk -> follow-up**.

Keep the causal account separate from the operational timeline when that improves clarity.

### Instruct

Use: **condition/prerequisite -> action -> expected result -> exception/recovery**.

Do not make the reader begin an action before learning the condition that determines whether it applies.

## Headings and lists

Use headings to reveal argument structure, not to decorate text. Prefer descriptive headings such as `Why the current retry policy overloads healthy regions` over generic headings such as `Background` when the stronger heading helps the reader scan the reasoning.

Use a list when the material is actually coordinate or sequential. Keep prose as prose when the relationship between sentences matters more than itemization.