# Examples

These examples illustrate transformations, not fixed templates.

## Engineering explanation: expose mechanism

Before:

> There are some cases where retries can cause increased load during failures, which may result in higher latency.

After:

> The client retries every failed request immediately. During a regional failure, those retries send additional traffic to the remaining healthy instances, increasing queue depth and latency.

Why it improves: the revision names the actor, action, failure condition, and causal chain.

## Design proposal: make recommendation inspectable

Before:

> We have explored a few approaches to improve cache behavior. One option would be adding a per-tenant cache. Another is changing eviction. After looking at the data, a per-tenant cache seems promising.

After:

> Add a per-tenant cache for metadata lookups. The current shared cache lets a few large tenants evict hot entries for everyone else, which accounts for most misses during peak load. Per-tenant partitions isolate that eviction pressure. The tradeoff is a small increase in total memory and more complex capacity tuning.

Why it improves: recommendation, evidence, mechanism, and tradeoff appear together instead of following discovery order.

## Leadership status: lead with consequence

Before:

> Over the past few weeks the team has been investigating planner performance. We ran several tests across different database sizes and found some interesting differences. We now think the new planner path is related to the latency regression.

After:

> The new planner path is the primary cause of the query-latency regression on databases above 2 TB. Disabling it for those tenants recovers about 30% of the lost performance. A full fix requires planner work and is likely to move the September milestone by about two weeks.

Why it improves: a leader gets state, evidence, mitigation, and schedule consequence before investigation history.

## Mixed audience: progressive disclosure

> **Recommendation:** keep the September preview date and disable the new planner path for databases above 2 TB. This recovers most user-visible latency at the cost of delaying the planner improvement for roughly 8% of preview tenants.
>
> **Why:** traces show the new path adds 250 to 400 ms at p95 on large databases because cardinality estimation selects a join strategy that performs poorly at that scale. Smaller databases do not show the regression.
>
> **Engineering detail:** ...

Why it improves: leadership can make the tradeoff from the first two paragraphs; engineers can continue into mechanism and evidence.

## Uncertainty: calibrate rather than fog

Weak:

> We think the rollout may be contributing to elevated CPU and are still investigating.

Better when evidence is partial:

> CPU rose 18% after the rollout. The new reconciliation worker accounts for about half of the additional samples in current profiles, but we have not yet explained the remainder.

Why it improves: uncertainty is preserved while the evidence boundary becomes visible.

## Revision: do not shorten away reasoning

Over-compressed:

> Use backoff to reduce retry load.

Better:

> Add exponential backoff with jitter. Immediate retries synchronize clients during regional failures and amplify traffic to healthy instances; backoff spreads those retries over time.

Why it improves: the extra words earn their keep by explaining why the recommendation works.