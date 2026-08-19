# Engineering writing

Optimize engineering prose for shared understanding, technical correctness, and the ability to inspect or challenge the reasoning.

## What engineering readers need

Make these easy to find when relevant:

- system behavior and mechanism;
- constraints and invariants;
- assumptions and dependencies;
- interfaces and ownership boundaries;
- failure modes and recovery behavior;
- alternatives and tradeoffs;
- evidence, measurements, and validation;
- unresolved questions and consequences.

Do not translate precise technical language into vague everyday language. Explain the term or mechanism instead.

## Technical explanations

Prefer this progression:

1. State what the system does or what changed.
2. Give the minimum mental model needed to understand it.
3. Explain the mechanism and causal chain.
4. Show a concrete example when it removes ambiguity.
5. Name important limits, edge cases, or failure modes.

Do not begin with implementation detail before the reader knows what problem that detail explains.

### Weak

> Requests can experience increased latency because retries happen in some failure cases and that can increase load.

### Better

> The client retries every failed request immediately. During a regional failure, those retries send additional traffic to the remaining healthy instances, which increases queue depth and latency. Exponential backoff with jitter reduces that synchronized retry load.

The second version exposes actor, mechanism, and consequence.

## Design and architecture proposals

Make the proposal inspectable. A useful default order is:

1. **Problem:** observable behavior or constraint, including why the status quo is insufficient.
2. **Recommendation:** the proposed design in concrete terms.
3. **Mechanism:** how the design produces the desired behavior.
4. **Constraints and invariants:** properties that must remain true.
5. **Alternatives:** serious options considered and why they lose under the stated criteria.
6. **Tradeoffs:** costs introduced by the recommendation.
7. **Failure modes and operational consequences:** what breaks, degrades, or becomes harder.
8. **Validation:** how to know the design works.
9. **Open questions:** unresolved items that could still change the design.

Do not present an alternative merely to dismiss it. Include it only if a reasonable engineer could choose it under different priorities.

## Status and incident writing

Separate what is known from what is suspected.

Prefer:

> p95 latency rose from 220 ms to 610 ms after the May 14 rollout. Traces show that the new planner path accounts for most of the added time on databases above 2 TB. We have disabled that path for large tenants while we test a planner fix.

Avoid:

> We believe the rollout may have caused some latency issues and are investigating several possible causes.

Use the second form only when the evidence is genuinely that weak. Uncertainty is fine; fog is not.

For incidents, distinguish:

- **impact:** what users or systems experienced;
- **trigger:** the event that started the failure, when known;
- **cause:** the mechanism that produced the impact;
- **contributing conditions:** factors that increased likelihood or severity;
- **mitigation:** what restored service;
- **corrective action:** what changes the future failure mode.

Do not collapse trigger, cause, and contributing condition into one vague "root cause" sentence.

## Instructions and runbooks

Put conditions before actions when acting too early would be harmful or confusing.

> If replication lag exceeds five minutes, pause the migration and check the replica logs.

Prefer one operational action per numbered step. Include the expected result when it helps the reader verify progress. Put warnings immediately before the action they constrain.

## Engineering tone

- Prefer exact nouns and strong verbs.
- Use equations, code, tables, diagrams, and lists when they convey structure better than prose.
- Do not hide disagreement behind neutral-sounding mush. Name the tradeoff.
- Do not perform false certainty. State the assumption or missing evidence.
- Avoid documentation that narrates repository history unless history is the subject. Describe the system as it is now.