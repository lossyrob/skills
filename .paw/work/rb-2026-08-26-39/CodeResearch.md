# Code Research

## Relevant surfaces

- `skills/backlog-orchestrator/references/triage.md:24` defines per-tier and per-issue configuration
  and owns the persisted run manifest schema.
- `skills/backlog-orchestrator/references/app-lifecycle.md:46` defines app implementer prompt
  substitutions.
- `skills/backlog-orchestrator/references/cli-lifecycle.md:34` defines CLI prompt rendering and
  substitutions.
- `skills/backlog-orchestrator/templates/app-implementer-prompt.md:63` and
  `skills/backlog-orchestrator/templates/cli-implementer-prompt.md:41` define worker PR-title
  requirements.
- `skills/backlog-orchestrator/SKILL.md:33` and `README.md:128` are the shared operator-facing
  documentation surfaces.
- `plugin.json:4` and `.github/plugin/marketplace.json:8` carry synchronized plugin versions.

## Implementation constraints

- Preserve `workstreamId` for coordination while removing it from the default PR title.
- Resolve configuration before worker dispatch so app and CLI workers receive the same deterministic
  contract.
- Keep older run manifests resumable by documenting an additive schema migration and backfill.

## Open Questions

None.

