# Implementation Plan

## Summary

Add a shared, persisted PR title format with a human-readable default, then pass it through both
runtime-specific worker prompt pipelines.

## Phases

- [x] Define format tokens, validation, default, manifest fields, and legacy migration.
- [x] Update app and CLI lifecycle substitutions and implementer prompts.
- [x] Update shared documentation and synchronized plugin metadata.
- [x] Validate links, placeholders, title rendering, JSON, and diff integrity.

## Open Questions

None.
