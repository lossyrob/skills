---
name: spar
description: A pairing-style critique skill run as sparring rounds. When you face a consequential decision under uncertainty, open a gated, multi-round critique episode with a different-model subagent (a "duck") that attacks your assumptions and surfaces failure modes and alternatives. You keep the pen; the pair advises and has no veto. Supports integrate-and-proceed or brief-back-to-operator. Use it when the operator asks to "pair", "spar", "rubber duck", "get a second opinion", "discuss amongst yourselves", or to consult another model before committing to an approach.
---
# Spar

Get a sharp second opinion from a different model before you commit to a
consequential decision.

This is a **pairing** skill, with one deliberate divergence. Human pair
programming avoids adversarial communication, but only because humans take tough
feedback badly. Between agents there is no ego to protect, so the optimal pairing
looks like **sparring**: the partner is adversarial *in service of the work, not
despite it*. You keep the structure of pairing — a shared goal, two perspectives
on every consequential decision, and the driver holding the pen — and drop the
ego-protecting hedging that turns review into a rubber stamp.

The pairing structure keeps sparring from becoming combative; the sparring norm
keeps pairing from becoming sycophantic. The two are mutual guardrails.

## What this is

- **You are the driver.** You hold the pen. The pair never implements, never
  decides, and has no veto. It advises; you integrate or reject.
- **The pair is a different model than you.** A genuine second perspective
  requires a different model, not an echo of your own reasoning. The pair runs as
  a rubber-duck subagent (a "duck"). When the driver is GPT-5.5, the default duck
  is Opus 4.8; when the driver is an Opus model, default to a strong GPT model.
  The operator or caller may pin a different model.
- **It is gated, not ambient.** You do not consult on every change. You open a
  deliberate episode when a decision is both consequential and uncertain.
- **Once opened, it is dialogic.** Gate the entrance, not the depth. A single
  review pass is not sparring; run several short rounds while they keep resolving
  the same decision.

## When to open a sparring episode

Open one when you are about to **make, revise, or abandon a consequential
commitment under uncertainty.** That is the whole rule; the cases below just
instantiate it:

- **Load-bearing decision** — before locking a design, contract, abstraction,
  data model, API behavior, concurrency model, migration strategy, or
  compatibility boundary.
- **Plan invalidation** — when evidence from the work materially contradicts the
  plan or an assumption it rested on.
- **Non-trivial fork** — when multiple viable approaches exist and the choice has
  real consequences for correctness, maintainability, compatibility, or future
  work.
- **Boundary change** — when the work appears larger, smaller, or different than
  the assigned scope, or wants to change scope, contract, or success criteria.
- **Repeated failure** — after two materially different failed attempts on the
  same hard problem, ask the pair to attack your assumptions rather than your
  code.

## When NOT to open one

Do not spar on routine coding, obvious fixes, mechanical refactors, ordinary
test failures, or "please review this diff." Opening episodes for trivial or
poorly scoped questions is the failure mode — it produces latency theater and
trains everyone to rubber-stamp. Open few episodes; make each one deep enough to
change your thinking.

## How to run an episode

1. **Frame the question.** State the specific decision and what you are uncertain
   about. Vague prompts ("review this") get vague critique.
2. **Give the duck a context packet.** The subagent lacks your conversation
   history, so hand it what it needs to be useful:
   - the current plan or intent;
   - the relevant files, constraints, and contracts;
   - what changed or surprised you;
   - the candidate options you are weighing;
   - the specific critique you want;
   - the non-goals and scope boundary.
3. **Demand sparring, not reassurance.** Instruct the duck to attack assumptions,
   find failure modes, name where the approach breaks, and propose better
   alternatives — not to validate. If it agrees, it must say why with evidence,
   not as a courtesy.
4. **Go a few rounds.** Respond to its critique, expose your reasoning and
   constraints, and let it sharpen from generic objection into targeted
   disagreement. Continue only while each round is resolving a live uncertainty
   about the same decision.
5. **Close explicitly.** Stop when you can state the chosen approach, the rejected
   alternatives, and the remaining risks. Then either revise your plan/approach
   to incorporate the critique, or record why the critique does not apply. Never
   silently accept or silently dismiss.

Run the duck with the `task` tool as a `rubber-duck` agent, overriding `model` to
the pairing model. For a real back-and-forth, run it in `background` mode and use
`write_agent` to send follow-up rounds, so the duck retains the episode's context
across turns.

## Modes

- **integrate** (default) — you consult, fold the outcome into the work, and
  proceed autonomously. Use this for implementation/planning decisions where you
  own the call.
- **brief-back** — you consult, then bring the operator a concise brief of the
  gaps, risks, and recommendations rather than acting. Use this when the operator
  asked you to "discuss amongst yourselves, then bring me back a brief," or when
  the decision is the operator's to make. The brief should distinguish what the
  pair agreed on, what it contested, and your recommendation.

If the caller does not specify a mode, infer it: a decision you own → integrate;
a decision the operator owns, or an explicit request for a brief → brief-back.

## Caller customization

Callers (prompts or operators) may layer context-specific instructions on top of
this skill: add domain-specific triggers, pin a particular pairing model, require
a specific mode, or point the episode at a specific artifact. The mechanics above
do not change — only what is on the table does.
