#Requires -Version 7.0
<#
.SYNOPSIS
Receive a parsed lifecycle loop result, reconciling durable run-directory
state when the attached Wait-LoopDetached.ps1 helper fails to produce
parseable JSON.

.DESCRIPTION
Implements the lifecycle source-of-truth invariant: the detached loop run
directory is authoritative, the attached waiter is only a transport. If
the waiter exits with parseable JSON, that is returned directly. If the
waiter produces empty or unparseable output (transient I/O glitch, helper
crash, console-redirection oddity), this function calls Get-LoopStatus.ps1
against the same run directory as a second-chance read. Only when BOTH
the waiter output and the direct status read fail to yield parseable JSON
is an exception thrown — and the exception text includes the original
waiter output, the status output, the parse errors, and the run directory
so the caller can decide whether to reattach, restart, or hand off.

This wrapper does not attempt to classify or act on the result; it only
guarantees that the agent does not silently lose a durable lifecycle
event behind an empty waiter pipe.

The Wait-LoopDetached.ps1 in lossyrob-skills v0.1.14+ already performs
the same durable-state recovery internally. This wrapper protects against
the second class of failure: the waiter process itself producing no
output to its caller (host shell glitch, redirection problem, parent
process kill), where in-process recovery cannot help.

.PARAMETER LoopWait
Absolute path to Wait-LoopDetached.ps1 from the sibling 'loop' skill.

.PARAMETER LoopStatus
Absolute path to Get-LoopStatus.ps1 from the sibling 'loop' skill.

.PARAMETER Manifest
The manifest object returned by Start-LoopDetached.ps1. Its .runDir
property identifies the detached run directory.

.PARAMETER PollIntervalSeconds
Forwarded to Wait-LoopDetached.ps1. Defaults to 30 seconds.

.OUTPUTS
A parsed status object (PSCustomObject) with the same shape that
Wait-LoopDetached.ps1 / Get-LoopStatus.ps1 emit.

.EXAMPLE
. "$loopScripts\Receive-LifecycleLoopResult.ps1"
$result = Receive-LifecycleLoopResult -LoopWait $loopWait -LoopStatus $loopStatus -Manifest $manifest
$result
#>

Set-StrictMode -Version 3.0

function Receive-LifecycleLoopResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LoopWait,
        [Parameter(Mandatory = $true)][string]$LoopStatus,
        [Parameter(Mandatory = $true)][object]$Manifest,
        [int]$PollIntervalSeconds = 30
    )

    $runDir = [string]$Manifest.runDir
    if ([string]::IsNullOrWhiteSpace($runDir)) {
        throw "Receive-LifecycleLoopResult: Manifest.runDir is missing or empty."
    }

    # Attempt 1: the waiter is the canonical source. Capture stderr too
    # so diagnostic information is preserved in the failure path.
    $waiterRaw = $null
    $waiterParseError = $null
    try {
        $waiterItems = & $LoopWait -RunDir $runDir -PollIntervalSeconds $PollIntervalSeconds 2>&1
        $waiterRaw = ($waiterItems | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    } catch {
        $waiterParseError = "waiter invocation failed: $($_.Exception.Message)"
    }

    if (-not [string]::IsNullOrWhiteSpace($waiterRaw)) {
        try {
            return $waiterRaw | ConvertFrom-Json
        } catch {
            $waiterParseError = "waiter output did not parse as JSON: $($_.Exception.Message)"
        }
    }

    # Attempt 2: read durable state directly. The waiter v0.1.14+ already
    # falls back to the run directory internally when its helper fails, so
    # this branch is exercised when the waiter itself produced no output
    # at all (process killed, parent shell ate stdout, etc).
    $statusRaw = $null
    $statusParseError = $null
    try {
        $statusItems = & $LoopStatus -RunDir $runDir 2>&1
        $statusRaw = ($statusItems | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    } catch {
        $statusParseError = "status invocation failed: $($_.Exception.Message)"
    }

    if (-not [string]::IsNullOrWhiteSpace($statusRaw)) {
        try {
            return $statusRaw | ConvertFrom-Json
        } catch {
            $statusParseError = "status output did not parse as JSON: $($_.Exception.Message)"
        }
    }

    # Both attempts failed. Surface everything the caller needs to triage
    # without re-invoking either helper.
    throw @"
Wait-LoopDetached.ps1 did not return parseable JSON, and Get-LoopStatus.ps1 did not recover durable state.
RunDir: $runDir
WaiterOutput: $waiterRaw
WaiterParseError: $waiterParseError
StatusOutput: $statusRaw
StatusParseError: $statusParseError
"@
}
