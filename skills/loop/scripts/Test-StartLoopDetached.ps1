#Requires -Version 7.0
<#
.SYNOPSIS
Regression tests for Start-LoopDetached.ps1 planning/dry-run behavior.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$startScript = Join-Path $scriptDir 'Start-LoopDetached.ps1'

$pass = 0
$fail = 0

function Assert-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Run
    )
    try {
        & $Run
        $script:pass++
        Write-Host "PASS  $Name" -ForegroundColor Green
    } catch {
        $script:fail++
        Write-Host "FAIL  $Name" -ForegroundColor Red
        Write-Host "      $($_.Exception.Message)" -ForegroundColor Red
    }
}

Assert-Case 'WatchUntilTerminal defaults TimeoutSeconds to 0 when timeout omitted' {
    $plan = & pwsh -NoProfile -ExecutionPolicy Bypass -File $startScript `
        -Name 'watch-default-timeout' `
        -CheckCommand 'exit 1' `
        -WatchUntilTerminal `
        -DryRun | ConvertFrom-Json

    if ($plan.timeoutSeconds -ne 0) { throw "expected timeoutSeconds 0, got $($plan.timeoutSeconds)" }
    if (-not $plan.watchUntilTerminal) { throw 'expected watchUntilTerminal true' }
    if ($plan.watchMode -ne 'watch-until-terminal') { throw "expected watchMode watch-until-terminal, got '$($plan.watchMode)'" }
    if ($plan.timeoutSecondsExplicit) { throw 'expected timeoutSecondsExplicit false' }
}

Assert-Case 'Explicit TimeoutSeconds wins with WatchUntilTerminal' {
    $plan = & pwsh -NoProfile -ExecutionPolicy Bypass -File $startScript `
        -Name 'watch-explicit-timeout' `
        -CheckCommand 'exit 1' `
        -WatchUntilTerminal `
        -TimeoutSeconds 123 `
        -DryRun | ConvertFrom-Json

    if ($plan.timeoutSeconds -ne 123) { throw "expected timeoutSeconds 123, got $($plan.timeoutSeconds)" }
    if (-not $plan.watchUntilTerminal) { throw 'expected watchUntilTerminal true' }
    if (-not $plan.timeoutSecondsExplicit) { throw 'expected timeoutSecondsExplicit true' }
}

Assert-Case 'Bounded mode remains default' {
    $plan = & pwsh -NoProfile -ExecutionPolicy Bypass -File $startScript `
        -Name 'bounded-default' `
        -CheckCommand 'exit 1' `
        -DryRun | ConvertFrom-Json

    if ($plan.timeoutSeconds -ne 3600) { throw "expected default timeoutSeconds 3600, got $($plan.timeoutSeconds)" }
    if ($plan.watchUntilTerminal) { throw 'expected watchUntilTerminal false' }
    if ($plan.watchMode -ne 'bounded') { throw "expected watchMode bounded, got '$($plan.watchMode)'" }
}

Write-Host ""
Write-Host ("Summary: {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor (& { if ($fail -gt 0) { 'Red' } else { 'Green' } })
if ($fail -gt 0) { exit 1 }
exit 0
