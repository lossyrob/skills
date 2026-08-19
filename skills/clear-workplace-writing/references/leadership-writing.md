# Leadership writing

Optimize leadership prose for comprehension, judgment, and action. Leadership readers often need less implementation detail, but they need more explicit significance.

## Lead with the governing point

Default to the answer before the investigation.

A leadership reader should usually learn, near the top:

- what happened or what you recommend;
- why it matters;
- the evidence that makes the claim credible;
- the material tradeoff, risk, or uncertainty;
- what decision, action, or attention is needed.

Do not force leaders to infer the ask from a technical narrative.

### Discovery order is rarely reading order

Weak:

> We began investigating query latency in April. We first looked at connection pooling, but those experiments did not explain the regression. We then investigated the planner and found...

Better:

> Query latency has increased 38% since April, primarily because the new planner path performs poorly on large tenant databases. A mitigation recovers about 30% of the regression. Fixing the remainder requires a planner change and is likely to move the September milestone by about two weeks.

Include the investigation history later only if it affects confidence, risk, or the decision.

## Preserve decision-relevant technical detail

Leadership writing is not technical writing with the nouns removed.

Keep technical detail when it changes:

- the size or likelihood of an impact;
- the available options;
- reversibility;
- schedule or cost;
- customer or operational risk;
- confidence in the evidence;
- ownership or dependency;
- strategic consequences.

Omit implementation detail that does not change any of those.

When jargon is necessary, define it in place rather than replacing it with a less precise concept.

## Make significance explicit

Do not write:

> Cache hit rate decreased from 91% to 84%.

when the reader needs:

> Cache hit rate fell from 91% to 84%, adding roughly 120 ms to p95 query latency for the largest tenants. The regression is now large enough to threaten the preview SLO.

Numbers need context. Give the relevant baseline, delta, time window, affected population, or consequence.

## Proposals and decisions

Use a recommendation-first structure when the evidence supports one:

1. **Recommendation or ask**
2. **Why now / why it matters**
3. **Evidence and reasoning**
4. **Material alternatives and tradeoffs**
5. **Risks and uncertainty**
6. **Decision or next step**

Do not manufacture balance. If one option is clearly better under the stated criteria, say so and explain why. If the choice genuinely depends on priorities, name the priority that flips the recommendation.

## Status updates

A useful leadership status update answers:

- Are we on track?
- What materially changed?
- What is the consequence?
- What is the largest risk or blocker?
- What action or decision comes next?

Separate informational updates from asks. Label the ask directly when a decision is required.

Do not bury bad news in the fourth paragraph. Surprise ages poorly.

## Mixed audiences

Use progressive disclosure:

1. Lead with the conclusion, impact, decision, or ask.
2. Give the essential reasoning and evidence.
3. Add technical detail in lower sections, appendices, or linked material.

The upper layer must remain accurate enough that an engineer would not object to it. The lower layer must remain understandable enough that a motivated leader can inspect the reasoning.

## Leadership tone

- Prefer measured confidence over grand language.
- State tradeoffs without apology or drama.
- Use concrete ownership and dates when they are known.
- Do not use "important", "strategic", "critical", or "significant" as substitutes for describing the consequence.
- Avoid ceremonial openings and conclusions. Start with content; end when the job is done.