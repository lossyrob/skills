# Runtime selection

Choose the orchestration runtime once, before prerequisites or triage, persist it as
`run_meta.runtime_mode`, and use that mode for the entire run. Never mix transports within a run.

## Automatic selection

Select **app** when all of these are true:

- workspace context identifies a GitHub Copilot app project session and supplies
  `project_session_id` plus `project_id`;
- `create_session` and `send_session_message` are available;
- session automation and archival tools are available.

Otherwise select **cli** when the session is running in Copilot CLI and telex,
`launch-copilot-terminal`, and `loop` are available. `paw-pr-lifecycle` is a shared prerequisite.

If both environments appear available, prefer **app** when project-session context exists. If neither
set is complete, report the missing prerequisites instead of silently switching after the run starts.
The user may explicitly request either mode; honor that request after validating its prerequisites.

## Mode dispatch

After selection, load only the mode-specific operational files:

| Runtime | Protocol/setup | Lifecycle | Implementer template | Reviewer template |
|---|---|---|---|---|
| `app` | [app-protocol.md](app-protocol.md) | [app-lifecycle.md](app-lifecycle.md) | [../templates/app-implementer-prompt.md](../templates/app-implementer-prompt.md) | [../templates/app-reviewer-prompt.md](../templates/app-reviewer-prompt.md) |
| `cli` | [telex-protocol.md](telex-protocol.md) | [cli-lifecycle.md](cli-lifecycle.md) | [../templates/cli-implementer-prompt.md](../templates/cli-implementer-prompt.md) | [../templates/cli-reviewer-prompt.md](../templates/cli-reviewer-prompt.md) |

The shared files remain authoritative in both modes:

- [triage.md](triage.md) for issue selection and policy configuration;
- [merge-gate.md](merge-gate.md) for merge-vs-human decisions;
- [reporting.md](reporting.md) for ledger, deferred work, and reports.

## Shared semantic contract

Both transports use the same event kinds and lifecycle meaning:
`review-ready`, `review-posted`, `review-approved`, `rereview-requested`, `merge-ready`, `blocked`,
`process-feedback`, `human-review-pending`, `merged`, `stand-down-merged`, and
`stand-down-human`.

App mode additionally uses `peer-registered` and `stand-down-complete` for session-id exchange and
safe archival. CLI mode uses telex dispositions and terminal teardown instead.
