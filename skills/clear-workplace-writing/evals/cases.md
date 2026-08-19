# Seed evaluation cases

## Case 1: Engineering explanation

**Audience:** engineering  
**Purpose:** explain

Source facts:

- client retries failed requests immediately;
- during regional failures, retries shift to healthy regions;
- healthy regions see synchronized load spikes;
- queue depth and p95 latency increase;
- proposed mitigation is exponential backoff with jitter.

Prompt: Explain why the team should add backoff. Preserve all facts.

A strong result should expose the causal mechanism rather than merely say backoff is a best practice.

## Case 2: Leadership status

**Audience:** leadership  
**Purpose:** report-status

Source facts:

- p95 query latency increased 38% since April;
- regression affects databases above 2 TB;
- traces implicate a new planner path;
- disabling the path recovers about 30% of the regression;
- full fix likely moves September milestone by two weeks;
- no final schedule decision has been made.

Prompt: Write a short status update for engineering and product leadership.

A strong result should lead with state and consequence, preserve schedule uncertainty, and avoid narrating the investigation.

## Case 3: Mixed-audience design proposal

**Audience:** mixed  
**Purpose:** propose

Source facts:

- shared metadata cache is 20 GB;
- three large tenants account for 62% of evictions;
- cache misses add 80 to 140 ms per lookup;
- proposal: per-tenant partitions with a shared overflow pool;
- estimated memory increase: 8%;
- operational drawback: capacity tuning becomes more complex;
- alternative: larger global cache would require about 35% more memory to reach the same modeled miss rate.

Prompt: Write the opening of a design proposal for engineers and leadership.

A strong result should make the recommendation and tradeoff clear before technical detail, then provide enough mechanism for engineers to challenge it.

## Case 4: Incident uncertainty

**Audience:** mixed  
**Purpose:** report-incident

Source facts:

- CPU increased 18% after a rollout;
- profiling attributes about half the additional samples to a new reconciliation worker;
- the rest is unexplained;
- disabling the worker reduced CPU by 9%;
- customer impact was elevated write latency for 23 minutes;
- service is recovered.

Prompt: Write an incident update. Do not overstate root cause confidence.

A strong result should distinguish impact, evidence, mitigation, and remaining uncertainty.

## Case 5: Preserve technical precision

**Audience:** leadership  
**Purpose:** decide

Source facts:

- option A provides read-after-write consistency within a region;
- option B provides eventual consistency and lower write latency;
- cross-region reads are eventually consistent under both options;
- workload has a hard requirement for read-after-write consistency in-region;
- option A costs 12% more at projected scale.

Prompt: Recommend an option for leadership.

A strong result must retain the exact consistency distinction. Replacing it with "more reliable" or "stronger consistency everywhere" is a failure.