---
name: council
description: Convene a bounded multi-model, multi-perspective deliberation to produce a recommendation with confidence, preserved dissent, and a transcript. Use on "council", "panel", "deliberate", "multi-agent review", "advisory council", "get diverse perspectives", or "discuss this with specialists".
---
# Council

Convene a bounded multi-model, multi-perspective deliberation when a decision is
important enough that one model's reasoning, or one critique loop, is not enough.
This is an **advisory council**, not a vote and not an ambient committee. The
driver or operator still owns the final decision.

The council pattern is for yes-and plus contest: first seed independent
perspectives, then let them refine, challenge, and synthesize toward a
recommendation while preserving dissent.

## What this is

- **A deliberative advisory process.** The goal is a better recommendation, not a
  transcript full of opinions.
- **The driver holds the pen.** Council members advise. They do not decide,
  implement, or veto.
- **Panel is a primitive, not the skill.** A panel is isolated fan-out of
  independent views. A council may start with a panel, then escalate into
  deliberation, debate, sparring, red-team, or Delphi-style rounds.
- **Dissent is first-class.** Do not force consensus. A useful council can end
  with a recommendation plus a minority report.
- **It is gated, not ambient.** Open a council only when extra perspectives are
  likely to beat a single frontier model with enough reasoning time.

## When to open a council

Open a council when the decision is both consequential and uncertain, especially:

- **High-stakes trade-offs** - architecture, product strategy, security posture,
  migrations, public commitments, compatibility boundaries, or workflow design.
- **Multi-faceted questions** - the answer depends on several valid lenses, such
  as user value, operational risk, maintainability, performance, and safety.
- **Real forks** - multiple plausible options exist and the choice changes future
  work.
- **Anchoring risk** - the main model may be locked into a frame, or a prior plan
  needs independent pressure.
- **User asks for specialists** - the operator wants a set of named models,
  personas, PAW SoT specialists, or perspectives.
- **Contradictory evidence** - existing findings conflict and need synthesis
  rather than another isolated critique.

## When NOT to open one

Do not use a council for routine coding, factual lookups, mechanical refactors,
simple bugs, ordinary test failures, or anything a single frontier model can
answer and verify directly. Multi-agent ceremony is a cost; spend it only when
diversity, adversarial testing, or synthesis is likely to change the outcome.

## Modes and primitives

Use `auto` unless the caller specifies a mode. In `auto`, choose the lightest
primitive that can resolve the uncertainty.

| Primitive | Use when | Shape |
| --- | --- | --- |
| `panel` | You need independent views, not interaction | Isolated fan-out -> synthesis |
| `deliberate` | You need collaboration and contest toward a recommendation | Panel -> focused exchange -> synthesis |
| `debate` | There are opposing positions or a binary/ternary fork | Assigned sides -> rebuttal -> judged synthesis |
| `spar` | One candidate recommendation needs a targeted pressure test | Prover -> verifier/challenger -> synthesis |
| `red-team` | A plan needs asymmetric attack/defense | Defender -> attacker -> mitigations |
| `delphi` | Authority effects or model dominance may distort the exchange | Anonymous or summary-mediated rounds |

Do not treat votes as authority. If you report counts, report them as evidence
about distribution of views, not as a decision rule.

## Depth

Choose depth from the task, or accept explicit caller configuration.

| Depth | Default shape | Use when |
| --- | --- | --- |
| `short` | 3 agents, one isolated panel round, one synthesis | Quick reversible trade-off |
| `medium` | 3-4 agents, panel plus one focused interaction round | Architecture/product/workflow decision |
| `long` | 4-5 agents, up to 3 rounds, required dissent report | High-stakes, irreversible, security, migration, or deep uncertainty |

Cap ordinary councils at 3 rounds. Past that, drift, sycophancy, and transcript
bloat usually cost more than they add. If a thread remains unresolved, preserve
it in the minority report or reopen conditions instead of spinning.

## How to run a council

1. **Frame the decision.** State the exact question, options under
   consideration, constraints, success criteria, non-goals, and what would change
   the recommendation.
2. **Decide whether council is warranted.** If a single-model answer with direct
   verification is enough, do not open a council. If the user explicitly asked
   for council, continue.
3. **Configure the roster.** Choose models, personas, lenses, and depth. Prefer
   heterogeneous frontier models for hard open-ended questions. If only one model
   family is available, make roles structurally different and keep the first
   round isolated.
4. **Create the artifact set.** Put it outside the repository unless the operator
   explicitly asks for a committed artifact. Use separate files for the brief,
   transcript, synthesis, and optional state metadata.
5. **Launch the contained council.** Give agents the brief path, transcript path,
   synthesis path, role cards, and file protocol. Do not relay each round through
   the main session.
6. **Let the council deliberate autonomously.** Agents run an isolated panel first,
   then escalate to the lightest interaction primitive that targets live
   disagreement. They write their own transcript and final synthesis.
7. **Read the synthesis, including its dissent, by default.** The main session
   integrates or briefs back from the synthesis artifact, and always reads the
   bounded `minority_report` and `reopen_conditions` fields so dissent is never
   silently dropped. It reads the raw transcript only on user request, failure,
   or an explicit audit trigger.
8. **Close explicitly.** State what the council concluded, what dissent remains,
   what would reopen the recommendation, and where the artifacts are.

## Roster and model selection

- Prefer **model diversity** over prompt-only persona diversity when the decision
  is hard or open-ended.
- Keep panel members close enough in capability that one model does not dominate
  the others by prestige. If a model is much weaker, use it as a focused critic,
  fact-checker, or peripheral reviewer, not an equal voter.
- Use personas to create cognitive diversity: pragmatic implementer, operations
  skeptic, first-principles designer, user advocate, risk analyst, red team,
  maintainer, domain specialist, or orthogonal-methods designer.
- Reuse PAW Society-of-Thought specialists when relevant: security,
  performance, assumptions, edge-cases, maintainability, architecture, testing,
  correctness, release-manager. Reuse perspectives such as baseline, premortem,
  red-team, and retrospective as overlays.
- If a caller pins models or personas, respect those pins unless they create an
  invalid council, such as a same-model judge evaluating its own output without
  dissent preservation.

## Council member contract

Every council member should output a structured turn:

```yaml
agent_id: short-stable-id
model: actual-model-used
persona: role or specialist name
epistemic_act: PROPOSE | SUPPORT | CHALLENGE | REFINE | CONCEDE | SYNTHESIZE
key_claim: one-sentence claim
confidence: HIGH | MEDIUM | LOW
grounds: evidence, assumptions, or reasoning that support the claim
warrant: why the grounds imply the claim
rebuttal_conditions: what would change or falsify this view
dissent_or_alignment: who this agrees or disagrees with, and why
relevance: CORE | ADJACENT | PARKED
smallest_change: the smallest direction-preserving fix, or "stop: <proof>"
what_gets_smaller: how this turn reduces uncertainty about the framed decision
```

Rules for members:

- Do not self-critique as a substitute for external critique.
- Do not concede because others disagree. Revise only when a specific flaw,
  missing evidence, or better frame is identified.
- If you agree, state why with evidence. Agreement without grounds is
  sycophancy.
- If you have no concern in your domain, say what you examined and why it
  passed. Do not fabricate a flaw to satisfy an adversarial prompt.
- Challenge specific claims, not personalities, model identities, or verbosity.
- Surface uncertainty explicitly.
- Classify each objection as CORE, ADJACENT, or PARKED against the framed
  decision. Do not promote an ADJACENT or PARKED concern into a pivot unless you
  prove the core decision fails without resolving it.
- A "this is broken, change direction" turn must carry the smallest
  direction-preserving alternative, or conclude `stop` with proof. Finding a
  defeater is not the goal; preserving or sharpening the decision is.
- Do not let stated confidence stand in for evidence. A confident assertion with
  weak grounds is weaker than a hedged one with strong grounds.

## Keeping the council on course

Multi-agent deliberation has a characteristic failure mode: a member is rewarded
for finding a "blocker," so a peripheral concern inflates into the center of the
work, and the confidence with which members argue starts to drive how important a
pivot seems. The council can then chase spikes and drift off the decision it was
opened to make. Guard against it explicitly.

- **Hold a decision vector.** The brief states the core decision, what is being
  made smaller or settled, the non-goals and parked topics, and the stop
  condition. Every round carries it. Members may challenge the vector only by
  proving the decision cannot succeed without revising it.
- **Conserve focus.** Classify findings as CORE, ADJACENT, or PARKED. Adjacent
  and parked concerns are recorded, not allowed to steer the recommendation,
  unless a member proves the core decision fails without them.
- **Reward sharper claims, not disagreement for its own sake.** Distinguish three
  outcomes:
  - *fake convergence* - a vaguer, mushier shared claim ("it depends", mutual
    hedging). Forbidden; push back to the real crux.
  - *genuine convergence* - a sharper, more specific shared claim. A win.
  - *named irreducible* - agreement that the decision reduces to one either-way
    that argument cannot settle. The best outcome of a thread; name the open
    variable and move on.
  Do not stage disagreement to keep a thread alive, and do not treat agreement as
  failure. A robust answer re-derived from independent angles is a result, not
  fatigue.
- **Make each round shrink the problem.** Every round should state what got
  smaller, clearer, or closer to action. Two consecutive rounds that shrink
  nothing end the council.
- **Separate confidence from grounding.** Weight findings by evidence and
  rebuttal-resistance, not by how confidently they are asserted. Flag a
  recommended pivot as decision-blocking only with proof, never on conviction
  alone.

These rules apply across primitives, but the success condition differs by mode.
In `debate`, sharpened disagreement or a named irreducible is the goal and easy
consensus is suspect. In `deliberate` and ideation-style work, convergence toward
a built recommendation is expected and fine; there the risk is vagueness and
dissolved forks, not premature agreement. State which success condition applies
before starting.

## Artifacts and containment

The council's inner deliberation should stay out of the main session context by
default. The main session launches the council, waits for completion through the
normal Copilot CLI subagent lifecycle, reads the synthesis artifact, and briefs
or integrates from that synthesis. The transcript remains auditable, but it is
not absorbed into the driver context unless there is a reason.

Use an artifact set:

```text
council-<id>/
  brief.md        # curated context pack for all council members
  transcript.md   # full deliberation, not read by the main session by default
  synthesis.md    # concise recommendation packet read by the main session
  state.json      # optional status, timestamps, agent ids, artifact paths
```

### Default: autonomous contained council

Use this for ordinary councils:

1. The driver writes `brief.md` with the decision frame, relevant context,
   constraints, options, non-goals, links to source artifacts, roster, depth, and
   output requirements.
2. The driver launches council agents in parallel or as configured, passing them
   paths to `brief.md`, `transcript.md`, `synthesis.md`, and `state.json` if used.
3. Agents coordinate through the transcript artifact and write the final
   synthesis artifact. The main session does not relay rounds or read the
   transcript as part of normal operation.
4. Copilot CLI's existing subagent lifecycle and notifications handle long-running
   work. If the run appears stale, the main session may inspect timestamps,
   state, or agent status, but liveness supervision is not the council's core
   deliberation protocol.
5. The main session reads `synthesis.md`, reports the conclusion, and provides
   the transcript path for audit.

This default optimizes for context hygiene: the main session is influenced by the
council's conclusion, not by every intermediate argument, persona, tangent, or
recency effect from the debate.

### Context packs

Council members do not inherit the main session's full context. Give them enough
context to deliberate well without forcing the main session to summarize the
entire conversation into its own prompt.

Default `brief.md` contents:

- the decision question and why council is being opened;
- options under consideration;
- constraints, success criteria, non-goals, and known risks;
- relevant files, diffs, issues, PRs, research reports, transcripts, or session
  artifacts by path;
- prior conclusions the council should treat as context, not as authority;
- roster, roles, models, depth, and mode;
- required output packet and audit triggers.

Optional deep context may include links to broader session artifacts or selected
conversation excerpts. Full-session-history loading is an explicit opt-in, not
the default: it can improve grounding, but it can also import irrelevant recency,
private context, stale assumptions, and prompt noise.

Council agents should read `brief.md` first, follow linked artifacts as needed,
and mark context gaps instead of guessing.

### Transcript protocol

For supervised dogfood, a Markdown transcript with a small state header is
acceptable. For stronger runs, prefer append-only JSONL plus a rendered Markdown
summary. The transcript or state file should include enough metadata for the main
session or user to inspect progress:

- append-only transcript entries or JSONL events;
- immutable turn IDs or a monotonic sequence counter;
- agent ids, models, personas, and round numbers;
- timestamps for each turn and, if useful, heartbeat/progress metadata;
- maximum rounds, wall-clock expectations, and explicit `done` / `failed` states;
- a single named owner of the terminal-state transition, which must be written
  while holding the lock;
- a stale-lock rule: any member may break the lock when the state header's last
  update timestamp exceeds a stated TTL, so a crashed lock-holder cannot deadlock
  the council;
- transcript path and synthesis path;
- required final synthesis before the main agent acts.

Do not overbuild subagent lifecycle handling in the skill. If an agent hangs, use
Copilot CLI's existing subagent status/notification behavior and the artifact
timestamps to decide whether to wait, inspect, or terminate. The skill's job is
to define deliberation and artifacts, not to replace the host's subagent manager.

### Audit model

The transcript is not hidden authority. It is deliberately out of the main
context by default and available for audit on request. To avoid a circular audit
model where every trigger depends on the synthesis confessing its own weakness,
the main session always surfaces the bounded `minority_report` and
`reopen_conditions` from the synthesis packet, regardless of triggers.

Read the raw transcript when:

- the user asks why the council concluded something;
- the synthesis reports low confidence or unresolved high-impact dissent;
- the synthesis is internally inconsistent or missing required fields;
- the run failed, timed out, or appears stale;
- a faithfulness check disputes the synthesis packet;
- the driver needs to verify a specific claim before acting.

## Synthesis packet

The final answer should be concise enough for the main session, but structured
enough to preserve the council's value:

```yaml
decision_vector: the core decision this council was opened to make
recommendation: the best current recommendation
confidence: HIGH | MEDIUM | LOW
convergence: genuine-sharper | named-irreducible | unresolved
confidence_basis:
  panel_distribution: where agents agreed or split
  decisive_evidence: what actually changed the recommendation
  foreman_assessment: how strong the synthesis is
decisive_arguments:
  - claim: ...
    source_agents: [...]
    evidence: ...
minority_report:
  - agent: ...
    position: ...
    why_not_adopted: ...
parked:
  - topic: ...
    why_parked: recorded but not allowed to steer this decision
open_questions:
  - ...
reopen_conditions:
  - If this condition changes, revisit the recommendation
audit_triggers:
  - when the raw transcript should be read before acting
faithfulness_check:
  by: agent id of a non-author member, or "independent-rapporteur"
  verdict: SUPPORT | DISPUTE
  note: one line asserting the packet matches the transcript
brief_path: path to the context pack
transcript_path: path to the artifact
synthesis_path: path to this packet
```

`recommendation`, `confidence`, `decisive_arguments` with their `source_agents`,
`minority_report`, `reopen_conditions`, `audit_triggers`, and the artifact paths
are required fields. `minority_report` and `reopen_conditions` are never omitted:
if there is genuinely no dissent, state that explicitly rather than dropping the
field. A synthesis missing any required field is itself an audit trigger.

The rapporteur may merge, deduplicate, classify, and recommend. It must not
erase dissent, invent new findings that no member raised, or pretend that
majority count is proof. It weights findings by grounding and rebuttal-resistance,
not by stated confidence, and it does not elevate an ADJACENT or PARKED concern
into the recommendation or a pivot without a member having proven the core
decision fails without it.

Prefer an **independent rapporteur** that did not hold a decisive position in the
deliberation. When the rapporteur is also a debater, a different member must add
the `faithfulness_check` stub: a one-line SUPPORT or DISPUTE asserting that the
synthesis packet faithfully reflects the transcript. A DISPUTE verdict is an
audit trigger.

## Modes

- **integrate** (default) - run the council, fold the synthesis into the work,
  and proceed. Use when the driver owns the decision.
- **brief-back** - run the council and report the recommendation, dissent, and
  risks to the operator without acting. Use when the operator owns the decision
  or explicitly asks agents to discuss and brief back.
- **artifact-only** - run or shape the council into an artifact without taking a
  decision. Use for planning, dogfood, or future implementation design.

Infer the mode from the caller. If unclear and the decision is consequential for
the operator, prefer **brief-back**.

## Caller customization

Callers may specify:

- models: `gpt-5.5`, `claude-opus-4.8`, `claude-opus-4.7-high`, etc.;
- personas or PAW SoT specialists;
- mode: `panel`, `deliberate`, `debate`, `spar`, `red-team`, `delphi`, or
  `auto`;
- depth: `short`, `medium`, `long`, or `auto`;
- transcript path or artifact policy;
- whether to return a concise brief or a full structured packet.

If the caller only asks for "a council", configure the smallest council likely
to change the answer: usually 3 diverse perspectives, isolated first round, one
focused interaction round only if needed, and a synthesis with dissent.
