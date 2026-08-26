# Plan

## Approach

Replace the required opaque workstream prefix with a configurable PR title format shared by app and
CLI orchestration. Persist a human-readable default in the run manifest, resolve it per issue during
triage, and pass it into both runtime-specific implementer prompts.

## Work items

1. Define the format tokens, default, validation, and legacy-manifest behavior.
2. Wire the resolved format and issue title through app and CLI lifecycle rendering.
3. Update both implementer prompts, shared documentation, and plugin metadata.
4. Validate Markdown links, prompt placeholders, JSON, and the final diff.

## Key decisions

- Default format: `{title} (#{issue})`.
- Supported tokens: `{title}`, `{issue}`, and `{workstream}`.
- Store a run-wide default plus the resolved per-issue value so initialization is convenient and
  per-issue overrides remain deterministic.
- Keep `workstreamId` as an orchestration identifier; include it in a PR title only when the selected
  format uses `{workstream}`.
