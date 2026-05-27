# PAW PR Lifecycle

Skill-style operating guide for PAW implementer and reviewer sessions that coordinate through GitHub PRs.

Start with [SKILL.md](SKILL.md). Launch prompts should point agents at this skill and provide only the task-specific variables: repo, issue, PR when known, optional workstream/tracker ID, optional base-branch guidance, and the GitHub login to authenticate as.

Requires the sibling [`loop`](../loop) skill for detached PowerShell workers. The bundled `scripts/Get-LoopScriptPaths.ps1` helper discovers the loop scripts automatically.

