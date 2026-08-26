# CLI per-issue execution (phase 3)

Sequential. Process issues by `position`; exactly one issue is actively driven at a time. Held
human-review terminal workers from earlier issues may coexist with the current pair.

## Resolve the launcher

Resolve the host helper from the installed `launch-copilot-terminal` skill. Do not assume a fixed
plugin path.

macOS:

```bash
launch=$(find "$HOME/.copilot" -type f \
  -path '*/launch-copilot-terminal/Launch-CopilotTerminal.sh' -print -quit)
test -n "$launch" && test -x "$launch"
```

Windows:

```powershell
$launch = (Get-ChildItem "$env:USERPROFILE\.copilot" -Recurse `
  -Filter 'Launch-CopilotTerminal.ps1' -ErrorAction SilentlyContinue |
  Select-Object -First 1).FullName
```

`repo_path` and `repo` come from `run_meta`. Launch from the local checkout; workers create their own
worktrees.

## Per-issue loop

1. **Mark running.** Update the issue row and lifecycle todo.

2. **Render UTF-8 prompts.**

   - [../templates/cli-implementer-prompt.md](../templates/cli-implementer-prompt.md) ->
     `<session-files>/prompts/impl-<n>.md`
   - [../templates/cli-reviewer-prompt.md](../templates/cli-reviewer-prompt.md) ->
     `<session-files>/prompts/review-<n>.md` when enabled

   Common substitutions: `{{runid}}`, `{{repo}}`, `{{issue}}`, `{{telexBackend}}`,
   `{{orchestratorAddress}}`, `{{ghNote}}`, and `{{baseBranch}}`. Implementer also receives
   `{{implAddress}}`, `{{reviewAddress}}`, `{{reviewerPresent}}`, `{{implConfig}}`, and
   `{{workstreamId}}`. Reviewer also receives `{{reviewAddress}}`, `{{implAddress}}`, and
   `{{reviewConfig}}`.

3. **Launch reviewer first, then implementer.**

   macOS:

   ```bash
   if [[ $reviewer_enabled == true ]]; then
     "$launch" --title "review #<n>" --color purple --cwd "<repo_path>" \
       --terminal "<terminal_app>" --prompt-file "<...>/review-<n>.md" \
       --copilot-arg=--allow-all --copilot-arg=--agent --copilot-arg=PAW-Review
   fi
   "$launch" --title "impl #<n>" --color green --cwd "<repo_path>" \
     --terminal "<terminal_app>" --prompt-file "<...>/impl-<n>.md" --copilot-arg=--allow-all
   ```

   Windows:

   ```powershell
   if ($reviewerEnabled) {
     & $launch -Title "review #<n>" -Color purple -Cwd "<repo_path>" `
       -PromptFile "<...>\review-<n>.md" -CopilotArgs @("--allow-all","--agent","PAW-Review")
   }
   & $launch -Title "impl #<n>" -Color green -Cwd "<repo_path>" `
     -PromptFile "<...>\impl-<n>.md" -CopilotArgs @("--allow-all")
   ```

   On macOS, `auto` uses Terminal.app. Use `iterm2` only when explicitly selected and disclose the
   one-time Automation consent prompt. Verify whether iTerm2 created a session before retrying a timed
   out launch. The reviewer uses `--agent PAW-Review`; the implementer is a general session that loads
   `paw-lite` from its prompt.

4. **Wait for a terminal telex event** (`merge-ready` or `blocked`). A `merged` from a past
   human-review hold may interleave. Log `process-feedback`; disposition actionable messages after
   handling them.

5. **Branch on event kind.**

   - `merge-ready`: read the field report and run [merge-gate.md](merge-gate.md).
     - `merge`: squash-merge, verify issue closure, send `stand-down-merged` to implementer and reviewer,
       and mark merged.
     - `human-review`: send `human-review-pending`, leave workers alive, mark human-review, and advance.
     - In both outcomes, insert every harvested deferred item into `deferred`.
   - `merged`: verify the human-pended PR is merged, send `stand-down-merged`, mark merged, and resume
     the current issue.
   - `blocked`: record and surface the blocker, send `stand-down-human`, mark blocked, and advance unless
     the user asks to pause.

6. **Advance.** Mark the lifecycle todo done and select the next pending issue. When no pending issues
   remain, resolve all open deferred items before the backlog report. Retire telex addresses only when
   no human-review holds remain.

## Stand-down and recovery

Workers remain alive through `merge-ready`. Auto-merged or abandoned work receives immediate
stand-down. Human-review workers keep the merge sentry and telex bridge alive until the builder merges
or abandons the PR.

No active liveness polling. If a worker is unexpectedly silent, inspect the run-scoped telex address
directory and GitHub state, then decide whether to relaunch or mark blocked. Avoid duplicate workers.
