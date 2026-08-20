# Core practices

Use these practices as an ordered editing method. Earlier passes outrank later
ones: accurate meaning matters more than elegant phrasing, and clear structure
matters more than sentence polish.

Source tags point to the bundled public-domain references:

- `Strunk R13`: rule 13 in *The Elements of Style* (1918);
- `Abbott R43`: rule 43 in *How to Write Clearly*;
- `Spencer §64`: section 64 in *The Philosophy of Style*;
- `Spencer PS`: Spencer's later Postscript.

The tags show influence, not authority. This guide deliberately qualifies or
rejects some historical advice.

## 1. Frame the work

Before drafting or revising, identify:

- the intended reader;
- the document's purpose;
- the response it should produce;
- the claims the available evidence supports;
- the level of technical detail the reader needs.

Use these answers to decide what belongs in the document. Do not force every
document into the same voice or template. [Spencer §28, §66, §67]

### Calibrate for the audience

**Engineering readers** usually need behavior, mechanism, constraints,
invariants, interfaces, failure modes, evidence, and unresolved questions.
Preserve precise terminology and enough detail to inspect the reasoning.

**Leadership readers** usually need the outcome or recommendation, why it
matters, credible evidence, material tradeoffs and risks, and a clear decision
or ask. Preserve technical detail when it changes impact, options,
reversibility, schedule, cost, confidence, or ownership.

**Mixed audiences** benefit from progressive disclosure: conclusion and
significance first, essential reasoning next, and technical detail below. Use a
different order when the reader's actual task calls for one.

## 2. Preserve meaning

### Protect the factual boundary

**Practice:** Preserve every material fact, number, date, qualification,
commitment, constraint, technical distinction, and open question.

**Why:** A polished sentence that changes the underlying claim is a failed
revision.

**Exception:** Remove material only when the user requests it or it is genuinely
irrelevant. Record any deletion that could affect interpretation.

### Keep epistemic categories visible

**Practice:** Distinguish observation, inference, assumption, recommendation,
prediction, and uncertainty.

**Why:** Readers need to know what the evidence establishes and where judgment
begins.

**Exception:** Labels are unnecessary when ordinary wording makes the boundary
clear.

### Preserve technical precision

**Practice:** Keep terms that encode real distinctions. Define unfamiliar terms
briefly when the audience may not know them. Use one name for one concept.

**Why:** Replacing a precise term with a familiar but broader word can make the
prose easier to read and harder to trust.

**Exception:** Prefer the familiar term when both terms mean the same thing in
context. Familiarity matters more than etymology. [Spencer §5, PS]

## 3. Organize for the reader

### Answer the reader's first question early

**Practice:** Put the governing result, recommendation, problem, or requested
action near the beginning.

**Why:** Workplace readers are usually deciding whether to understand,
challenge, approve, prioritize, or act. Give them the object of that work.

**Exception:** Lead with a condition or qualification when acting on the main
claim before seeing it would be unsafe or misleading. Do not import Spencer's
preference for long, qualifier-first periodic sentences as a document-level
rule.

### Use reading order rather than discovery order

**Practice:** Group evidence beneath the claim it supports. Preserve chronology
when sequence explains causation, an incident, or a procedure.

**Why:** Readers should not have to reenact an investigation before learning
what it found.

**Exception:** Discovery history belongs when it changes confidence, rules out
an important alternative, or is itself the subject.

### Give each paragraph and sentence one controlling job

**Practice:** Build paragraphs around one topic and sentences around one
principal subject of thought. Split heterogeneous sentences. [Strunk R8, R9;
Abbott R43]

**Why:** A reader can place each claim without reconstructing how several ideas
fit together.

**Exception:** Combine tightly related ideas when their relationship is clearer
in one sentence than in several.

### Use structure only when it reveals logic

**Practice:** Use headings for meaningful divisions and lists for genuinely
coordinate or sequential material. Use prose when the relationship between
sentences carries the argument.

**Why:** Formatting should expose relationships rather than decorate the page.

**Exception:** Short documents often need no headings.

## 4. Expose the reasoning

### Make causal chains explicit

**Practice:** Connect condition, mechanism, observation, and consequence when
the claim depends on causation.

**Why:** A sequence of facts does not explain why one produced another.

**Exception:** Do not invent a mechanism when the evidence establishes only a
correlation. State that limit.

### Attach evidence to the claim it supports

**Practice:** Put measurements near the conclusion they justify. Include the
relevant baseline, comparison, time window, affected population, and caveats.

**Why:** Detached numbers force readers to infer both meaning and significance.

**Exception:** A supporting table may hold detailed evidence when the prose
states the conclusion and points to it precisely.

### Make alternatives and tradeoffs inspectable

**Practice:** Compare serious alternatives against criteria named before the
comparison. State the cost introduced by the recommendation.

**Why:** Readers can challenge the reasoning without reverse-engineering the
rubric.

**Exception:** Do not manufacture balance or invent an objection. Include an
alternative only when a reasonable reader might choose it under different
priorities.

## 5. Repair sentences

### Expose actors and actions

**Practice:** Put important actors in subjects and important actions in verbs.
Prefer active voice when it makes agency clearer. [Strunk R10; Abbott R11a]

**Why:** Nominalizations and agentless constructions often hide ownership,
mechanism, or responsibility.

**Exception:** Passive voice works when the actor is unknown, irrelevant,
intentionally omitted, or when the object is already the paragraph's topic.

### Keep related words together

**Practice:** Place modifiers, clauses, pronouns, and the words they govern close
together. Put `only` next to what it limits. [Strunk R16; Abbott R19-R29;
Spencer §24]

**Why:** Long separations make readers hold unresolved material and invite
scope errors.

**Exception:** Do not front-load so many qualifications that the main clause
becomes difficult to reach. Use an intermediate structure for complex
sentences. [Spencer §27, §30, §32]

### Move from context to new information

**Practice:** Begin sentences from context the reader already has and place the
important new information where it receives natural emphasis, often near the
end. [Strunk R18; Abbott R15]

**Why:** This creates continuity while giving the new claim weight.

**Exception:** Put the new information first when urgency, contrast, or the
reader's question makes that position clearer.

### Use parallel form for parallel ideas

**Practice:** Express coordinate ideas in matching grammatical forms and avoid
unexpected changes of construction. [Strunk R15; Abbott R22, R40a]

**Why:** Form should reveal which ideas occupy the same logical level.

**Exception:** Vary form when parallelism would sound mechanical or obscure a
real difference.

## 6. Choose words deliberately

### Prefer exact, concrete language

**Practice:** Use exact nouns, verbs, mechanisms, examples, and measurements
when they are available. [Strunk R12; Abbott R1, R11; Spencer §9, §10]

**Why:** Concrete claims are easier to understand and test.

**Exception:** Abstract terms are correct for abstract ideas, and technical
terms may be more precise than concrete substitutes. [Spencer PS]

### Cut words that do no work

**Practice:** Remove ceremony, circumlocution, filler, repeated conclusions,
empty intensifiers, and transitions that add no logical relationship. Prefer a
verb to a verbal noun when it expresses the action directly. [Strunk R13;
Abbott R3, R11a, R47a, R54]

**Why:** These words consume attention without adding meaning.

**Exception:** Keep definitions, evidence, caveats, orientation, deliberate
rhythm, and useful repetition. Brevity yields to clarity. [Abbott R56; Spencer
PS]

### Do not rotate synonyms for variety

**Practice:** Repeat the established term for a component, metric, concept, or
decision.

**Why:** Slightly different words suggest slightly different meanings.
Repetition is cheaper than ambiguity. [Abbott R54]

**Exception:** Vary ordinary prose when the words are truly interchangeable and
the variation does not blur a technical concept.

## 7. Control emphasis and preserve voice

### Let evidence carry emphasis

**Practice:** Reserve emphatic language and dramatic structure for claims that
earn it. Do not make every sentence, section, or transition sound climactic.
[Abbott R2; Spencer §64, §65]

**Why:** Constant emphasis exhausts attention and makes real priorities harder
to detect.

**Exception:** Strong language is appropriate when the consequence and evidence
support it.

In particular:

- avoid generic emphasis such as `crucial`, `important`, `powerful`,
  `significant`, `unusual`, and their adverb forms unless the sentence
  explains the magnitude;
- avoid dramatic transitions such as `this is exactly where`;
- avoid announcing concision with `put simply`, `in one sentence`, `in one
  breath`, or `the key takeaway is`;
- avoid repeating the same conclusion in a heading, opening, and closing.

### Lead with the positive claim

**Practice:** State the substantive point directly. Avoid reflexive negative
parallelism such as `not X, but Y`, `it is X, not Y`, and `this is not merely
X`.

**Why:** Invented contrast adds drama and can imply an objection the audience
does not hold.

**Exception:** Use contrast when the reader is likely to hold the mistaken view
and correcting it materially advances the argument. This project deliberately
does not adopt Abbott R41 as a general recommendation.

### Prefer literal precision to stock metaphor

**Practice:** Prefer concrete nouns and verbs over promotional metaphors such as
`fuel`, `unlock`, `journey`, and `game changer`.

**Why:** Familiar metaphors often replace the mechanism or consequence the
reader needs.

**Exception:** Keep a metaphor when it is simple, accurate, and faster to grasp
than a literal explanation. [Spencer §43] This project deliberately rejects
Abbott R13 and R46 as general rules.

### Preserve a human voice

**Practice:** Keep the author's natural degree of warmth, rhythm, humor,
directness, and idiom. Match the level of detail and formality to the reader and
purpose.

**Why:** Clarity does not require sterile or uniform prose.

**Exception:** Change an intentional flourish when it obscures meaning,
overstates evidence, or conflicts with the requested tone.

Use comparisons only when they clarify a real distinction. Keep sentences
focused rather than chaining many clauses and qualifications. Use em dashes
sparingly.

## Final passes

### Keep

Check that the revision still contains:

- every fact, number, qualification, commitment, and technical distinction;
- enough evidence to trust the conclusion;
- enough mechanism to understand a causal claim;
- definitions for unfamiliar terms;
- caveats and uncertainty that affect a decision;
- the author's intended voice.

### Cut

Check for:

- buried governing points and purposeless chronology;
- unsupported claims or invented implications;
- vague actors, nominalizations, and ambiguous modifiers;
- needless words and synonym rotation;
- unsupported intensifiers and constant emphasis;
- negative parallelism and invented objections;
- canned openings, meta-commentary, and repeated conclusions.

Stop when another change would trade away accuracy, useful nuance, natural
voice, or comprehension. [Spencer §27]
