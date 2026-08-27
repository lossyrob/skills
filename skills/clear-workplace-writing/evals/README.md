# Evaluation notes

Use these cases to compare three conditions:

1. no writing skill;
2. the original skill at commit `57efef5`;
3. the current candidate.

Keep the prompt, model, source facts, and judging procedure constant. Treat
`57efef5` as the regression control: a candidate should beat or tie it on real
work examples rather than merely outperforming no guidance. A useful evaluation
should reward reader usefulness, not mechanical rule compliance.

Score each result from 1 to 5 on:

1. **Main-point accessibility:** how quickly the intended reader can identify the governing point.
2. **Audience fit:** whether the detail and structure match engineering, leadership, or mixed readers.
3. **Reasoning visibility:** whether mechanisms, evidence, tradeoffs, and uncertainty are inspectable.
4. **Technical precision:** whether meaningful distinctions and terminology remain correct.
5. **Factual preservation:** whether the rewrite avoids invented or dropped material claims.
6. **Reader effort:** whether the prose removes avoidable decoding, chronology, repetition, or abstraction.
7. **Actionability:** whether a reader can tell what decision, action, or conclusion follows when the task calls for one.
8. **Voice preservation:** whether the prose remains natural rather than mechanically flattened.

Also record failure flags:

- invented evidence or certainty;
- material fact omitted;
- technical term simplified incorrectly;
- recommendation strengthened beyond the evidence;
- meaningful caveat lost;
- excessive compression;
- discovery chronology retained without purpose;
- generic "executive" language that obscures the real technical issue.
- invented contrast or objection;
- unsupported emphasis;
- unnecessary rewriting of already-clear prose;
- voice flattened into generic corporate language.

The skill should win because readers can understand and act more reliably, not because it uses fewer words.