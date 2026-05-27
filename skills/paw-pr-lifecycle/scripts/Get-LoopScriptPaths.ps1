<#
.SYNOPSIS
Resolve absolute paths to the sibling `loop` skill's detached-worker scripts.

.DESCRIPTION
The paw-pr-lifecycle skill orchestrates PAW PR loops by handing CheckCommand
strings to the `loop` skill's detached worker. The `loop` skill is a sibling
skill in the lossyrob-skills plugin, but the installed location varies by
plugin manager. This helper resolves the three loop scripts the lifecycle
skill needs and emits a single JSON object the agent can capture and reuse.

Resolution order:
  1. Sibling skill directory (`..\loop\scripts`), used when this skill is
     checked out from the lossyrob/skills repo or installed alongside `loop`.
  2. Default plugin install path
     (`$HOME\.copilot\installed-plugins\lossyrob-skills\lossyrob-skills\skills\loop\scripts`).
  3. Bare-skills install path (`$HOME\.copilot\skills\loop\scripts`).
  4. Recursive fallback under `$HOME\.copilot` for the three known script
     filenames (slow path; used only if 1-3 miss).

The script throws if any of the three target scripts is unresolved, so the
caller can fail fast instead of constructing a malformed CheckCommand.

.OUTPUTS
A compact JSON object with `detached`, `wait`, and `status` properties, each
holding an absolute filesystem path.

.EXAMPLE
$loopPaths = & "$skillDir\scripts\Get-LoopScriptPaths.ps1" | ConvertFrom-Json
$loopDetached = $loopPaths.detached
$loopWait     = $loopPaths.wait
$loopStatus   = $loopPaths.status
#>

[CmdletBinding()]
param(
  [string]$LoopSkillRoot
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$targets = @{
  detached = 'Start-LoopDetached.ps1'
  wait     = 'Wait-LoopDetached.ps1'
  status   = 'Get-LoopStatus.ps1'
}

function Test-LoopRoot {
  param([string]$Root)
  if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $false }
  foreach ($name in $targets.Values) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root $name) -PathType Leaf)) {
      return $false
    }
  }
  return $true
}

$candidates = [System.Collections.Generic.List[string]]::new()

if (-not [string]::IsNullOrWhiteSpace($LoopSkillRoot)) {
  [void]$candidates.Add($LoopSkillRoot)
}

# 1. Sibling skill in a checked-out skills repo or co-installed plugin layout.
$skillsDir = Split-Path -Parent $PSScriptRoot | Split-Path -Parent
if ($skillsDir) {
  [void]$candidates.Add((Join-Path $skillsDir 'loop\scripts'))
}

# 2. Default Copilot plugin install path for lossyrob-skills.
[void]$candidates.Add((Join-Path $HOME '.copilot\installed-plugins\lossyrob-skills\lossyrob-skills\skills\loop\scripts'))

# 3. Bare-skills install path (~/.copilot/skills/<name>).
[void]$candidates.Add((Join-Path $HOME '.copilot\skills\loop\scripts'))

$resolvedRoot = $null
foreach ($candidate in $candidates) {
  if (Test-LoopRoot -Root $candidate) {
    $resolvedRoot = (Resolve-Path -LiteralPath $candidate).ProviderPath
    break
  }
}

# 4. Recursive fallback under ~/.copilot only if structured candidates miss.
if ($null -eq $resolvedRoot) {
  $copilotRoot = Join-Path $HOME '.copilot'
  if (Test-Path -LiteralPath $copilotRoot -PathType Container) {
    $found = Get-ChildItem -Path $copilotRoot -Recurse -Filter $targets.detached -ErrorAction SilentlyContinue |
      Where-Object { Test-LoopRoot -Root $_.DirectoryName } |
      Select-Object -First 1
    if ($found) {
      $resolvedRoot = $found.DirectoryName
    }
  }
}

if ($null -eq $resolvedRoot) {
  $searched = ($candidates | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
  throw "Unable to locate sibling 'loop' skill scripts. Searched:`n$searched`nInstall the lossyrob-skills plugin (which provides both 'loop' and 'paw-pr-lifecycle') or pass -LoopSkillRoot explicitly."
}

[ordered]@{
  detached = (Join-Path $resolvedRoot $targets.detached)
  wait     = (Join-Path $resolvedRoot $targets.wait)
  status   = (Join-Path $resolvedRoot $targets.status)
} | ConvertTo-Json -Compress
