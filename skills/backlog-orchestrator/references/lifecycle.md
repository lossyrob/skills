# Per-issue execution dispatcher (phase 3)

Read `run_meta.runtime_mode` and load exactly one lifecycle:

- `app` -> [app-lifecycle.md](app-lifecycle.md)
- `cli` -> [cli-lifecycle.md](cli-lifecycle.md)

Do not combine app child sessions with telex workers in one run. Shared merge-gate, reporting, and
deferred-work behavior remain identical; only worker creation, messaging, sentry wakeups, and cleanup
are runtime-specific.
