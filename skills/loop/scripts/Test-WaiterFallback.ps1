#Requires -Version 7.0
<#
.SYNOPSIS
Regression tests for Wait-LoopDetached.ps1 durable-state fallback.

.DESCRIPTION
Covers the RCA scenarios from 2026-05-25 where the attached waiter failed
to invoke Get-LoopStatus.ps1 and silently lost an actionable detached
loop result. The fixed waiter must:

  - Recover actionable / final classifications directly from durable run
    directory files (manifest.json, last-result.json, events/*.json).
  - Exit through the normal Write-StatusAndExit path with
    waiter.exitReason = 'status_read_fallback' when durable read recovers
    a real lifecycle event.
  - Fall back to exit 121 (waiter_internal_error) with a JSON status only
    when the durable read also yields nothing actionable.
  - Never lose an actionable last-result.json behind a bare-text failure.

Run with PowerShell 7+:

    pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-WaiterFallback.ps1

Exit code 0 if all cases pass, 1 otherwise.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$srcWaiter = Join-Path $scriptDir 'Wait-LoopDetached.ps1'

if (-not (Test-Path -LiteralPath $srcWaiter -PathType Leaf)) {
    throw "Cannot find Wait-LoopDetached.ps1 at $srcWaiter"
}

function New-TestRunDir {
    $dir = Join-Path $env:TEMP ("waiter-test-rundir-{0:N}" -f ([guid]::NewGuid()))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function New-TestWaiterDir {
    # Copy Wait-LoopDetached.ps1 into a temp dir and stub Get-LoopStatus.ps1
    # so we can simulate a failed status helper.
    param([scriptblock]$StubBody)
    $dir = Join-Path $env:TEMP ("waiter-test-bin-{0:N}" -f ([guid]::NewGuid()))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item -LiteralPath $srcWaiter -Destination $dir
    $stubText = "[CmdletBinding()] param([string]`$RunDir, [int]`$GraceSeconds = 30)`r`n" + $StubBody.ToString()
    Set-Content -LiteralPath (Join-Path $dir 'Get-LoopStatus.ps1') -Value $stubText -Encoding utf8
    return $dir
}

function New-TestWaiterDirWithoutStatusHelper {
    $dir = Join-Path $env:TEMP ("waiter-test-bin-{0:N}" -f ([guid]::NewGuid()))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item -LiteralPath $srcWaiter -Destination $dir
    return $dir
}

function Invoke-Waiter {
    param(
        [Parameter(Mandatory)][string]$WaiterDir,
        [Parameter(Mandatory)][string]$RunDir
    )
    $waiter = Join-Path $WaiterDir 'Wait-LoopDetached.ps1'
    $out = & pwsh -NoProfile -ExecutionPolicy Bypass -File $waiter -RunDir $RunDir -PollIntervalSeconds 1 -StatusReadRetries 1 -GraceSeconds 1
    $ec = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $ec
        Stdout = ($out | Out-String).Trim()
        Json = $null
    }
}

function Add-LastResult {
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][hashtable]$Result
    )
    $path = Join-Path $RunDir 'last-result.json'
    [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        loopStatus = $Result.loopStatus
        status = $Result.status
        event = $Result.event
        terminal = $Result.terminal
        stdout = $Result.stdout
        checkExitCode = $Result.checkExitCode
    } | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8
}

function Add-Event {
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][hashtable]$Result,
        [string]$Name = '0001.json'
    )
    $eventsDir = Join-Path $RunDir 'events'
    New-Item -ItemType Directory -Path $eventsDir -Force | Out-Null
    $path = Join-Path $eventsDir $Name
    [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        result = $Result
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8
}

$throwStub = { throw "simulated Get-LoopStatus internal error" }
$emptyStub = { Write-Host -NoNewline "" }  # exits 0 with no output

$pass = 0; $fail = 0
$cleanups = @()

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

# ----------------------------------------------------------------------------
# Case 1 (RCA core): helper throws, last-result.json has actionable event.
# Waiter must exit with the actionable code and emit status_read_fallback.
# ----------------------------------------------------------------------------
Assert-Case 'helper-throws + actionable last-result + matching event => status_read_fallback (actionable)' {
    $waiterDir = New-TestWaiterDir -StubBody $throwStub
    $runDir = New-TestRunDir
    $script:cleanups += $waiterDir, $runDir

    $actionableResult = @{
        loopStatus = 'actionable'
        status = 'ACTION'
        event = 'rereview_requested'
        terminal = $true
        stdout = '{"status":"ACTION","event":"rereview_requested","pullRequest":616}'
        checkExitCode = 23
    }
    Add-LastResult -RunDir $runDir -Result $actionableResult
    Add-Event -RunDir $runDir -Result $actionableResult

    $r = Invoke-Waiter -WaiterDir $waiterDir -RunDir $runDir
    if ($r.ExitCode -ne 23) { throw "expected exit 23 (actionable checkExitCode), got $($r.ExitCode). stdout: $($r.Stdout)" }
    $obj = $r.Stdout | ConvertFrom-Json
    if ($obj.waiter.exitReason -ne 'status_read_fallback') { throw "expected waiter.exitReason='status_read_fallback', got '$($obj.waiter.exitReason)'" }
    if ($obj.waiterFallbackSource -ne 'durable_files') { throw "expected waiterFallbackSource='durable_files', got '$($obj.waiterFallbackSource)'" }
    if ($obj.classification -ne 'actionable') { throw "expected classification='actionable', got '$($obj.classification)'" }
    if (-not $obj.recoveredFromDurableFiles) { throw "expected recoveredFromDurableFiles=true" }
    if (-not ($obj.waiterFallbackDurableSources -contains 'lastResult')) { throw "expected lastResult in waiterFallbackDurableSources" }
    if (-not ($obj.waiterFallbackDurableSources -contains 'latestEvent')) { throw "expected latestEvent in waiterFallbackDurableSources" }
    if ($obj.lastResult.event -ne 'rereview_requested') { throw "lastResult.event not preserved" }
    if (-not $obj.lastWake) { throw "expected lastWake metadata" }
    if ($obj.lastWake.kind -ne 'actionable') { throw "expected lastWake.kind actionable, got '$($obj.lastWake.kind)'" }
    if ($obj.lastWake.exitCode -ne 23) { throw "expected lastWake.exitCode 23, got '$($obj.lastWake.exitCode)'" }
    if ($obj.lastWake.event -ne 'rereview_requested') { throw "expected lastWake.event rereview_requested, got '$($obj.lastWake.event)'" }
}

# ----------------------------------------------------------------------------
# Case 1b: status helper missing entirely, last-result.json has actionable event.
# This is the missing-helper RCA: no bare-text exit 3 is allowed.
# ----------------------------------------------------------------------------
Assert-Case 'missing helper + actionable last-result + matching event => status_read_fallback (actionable)' {
    $waiterDir = New-TestWaiterDirWithoutStatusHelper
    $runDir = New-TestRunDir
    $script:cleanups += $waiterDir, $runDir

    $actionableResult = @{
        loopStatus = 'actionable'
        status = 'ACTION'
        event = 'domain_event_requires_agent'
        terminal = $true
        stdout = '{"status":"ACTION","event":"domain_event_requires_agent"}'
        checkExitCode = 31
    }
    Add-LastResult -RunDir $runDir -Result $actionableResult
    Add-Event -RunDir $runDir -Result $actionableResult

    $r = Invoke-Waiter -WaiterDir $waiterDir -RunDir $runDir
    if ($r.ExitCode -ne 31) { throw "expected exit 31 (actionable checkExitCode), got $($r.ExitCode). stdout: $($r.Stdout)" }
    $obj = $r.Stdout | ConvertFrom-Json
    if ($obj.waiter.exitReason -ne 'status_read_fallback') { throw "expected waiter.exitReason='status_read_fallback', got '$($obj.waiter.exitReason)'" }
    if ($obj.classification -ne 'actionable') { throw "expected classification='actionable', got '$($obj.classification)'" }
    if (-not $obj.lastWake) { throw "expected lastWake metadata" }
    if ($obj.lastWake.exitCode -ne 31) { throw "expected lastWake.exitCode 31, got '$($obj.lastWake.exitCode)'" }
}

# ----------------------------------------------------------------------------
# Case 2: helper returns empty + terminal success last-result.
# Waiter must exit 0 (final success) via status_read_fallback.
# ----------------------------------------------------------------------------
Assert-Case 'helper-empty + terminal success => status_read_fallback (exit 0)' {
    $waiterDir = New-TestWaiterDir -StubBody $emptyStub
    $runDir = New-TestRunDir
    $script:cleanups += $waiterDir, $runDir

    $finalSuccess = @{
        loopStatus = 'success'
        status = 'STOP'
        event = 'completed'
        terminal = $true
        stdout = ''
        checkExitCode = 0
    }
    Add-LastResult -RunDir $runDir -Result $finalSuccess
    Add-Event -RunDir $runDir -Result $finalSuccess

    $r = Invoke-Waiter -WaiterDir $waiterDir -RunDir $runDir
    if ($r.ExitCode -ne 0) { throw "expected exit 0 (final success), got $($r.ExitCode). stdout: $($r.Stdout)" }
    $obj = $r.Stdout | ConvertFrom-Json
    if ($obj.waiter.exitReason -ne 'status_read_fallback') { throw "expected status_read_fallback, got '$($obj.waiter.exitReason)'" }
    if ($obj.classification -ne 'final') { throw "expected classification='final', got '$($obj.classification)'" }
    if (-not $obj.lastWake) { throw "expected lastWake metadata" }
    if ($obj.lastWake.kind -ne 'final') { throw "expected lastWake.kind final, got '$($obj.lastWake.kind)'" }
    if ($obj.lastWake.exitCode -ne 0) { throw "expected lastWake.exitCode 0, got '$($obj.lastWake.exitCode)'" }
}

# ----------------------------------------------------------------------------
# Case 3: helper throws, run directory has no durable state.
# Waiter must exit 121 with waiter_internal_error and parseable JSON.
# ----------------------------------------------------------------------------
Assert-Case 'helper-throws + empty rundir => 121 stub_only' {
    $waiterDir = New-TestWaiterDir -StubBody $throwStub
    $runDir = New-TestRunDir
    $script:cleanups += $waiterDir, $runDir

    $r = Invoke-Waiter -WaiterDir $waiterDir -RunDir $runDir
    if ($r.ExitCode -ne 121) { throw "expected exit 121, got $($r.ExitCode). stdout: $($r.Stdout)" }
    $obj = $r.Stdout | ConvertFrom-Json
    if ($obj.waiter.exitReason -ne 'waiter_internal_error') { throw "expected waiter_internal_error, got '$($obj.waiter.exitReason)'" }
    if ($obj.waiterFallbackSource -ne 'stub_only') { throw "expected stub_only, got '$($obj.waiterFallbackSource)'" }
}

# ----------------------------------------------------------------------------
# Case 4: helper throws + malformed last-result.json + no events.
# Waiter must still emit JSON (121, waiter_internal_error) with the error
# recorded in waiterErrors. Must not crash, must not emit bare text.
# ----------------------------------------------------------------------------
Assert-Case 'helper-throws + malformed last-result + no events => 121 with structured diagnostic' {
    $waiterDir = New-TestWaiterDir -StubBody $throwStub
    $runDir = New-TestRunDir
    $script:cleanups += $waiterDir, $runDir
    Set-Content -LiteralPath (Join-Path $runDir 'last-result.json') -Value '{ this is not valid json' -Encoding utf8

    $r = Invoke-Waiter -WaiterDir $waiterDir -RunDir $runDir
    if ($r.ExitCode -ne 121) { throw "expected exit 121, got $($r.ExitCode). stdout: $($r.Stdout)" }
    $obj = $r.Stdout | ConvertFrom-Json
    if ($obj.waiter.exitReason -ne 'waiter_internal_error') { throw "expected waiter_internal_error, got '$($obj.waiter.exitReason)'" }
    # waiterErrors must include the underlying status-read error.
    $hasError = $false
    foreach ($e in @($obj.waiterErrors)) {
        if ($e -match 'simulated Get-LoopStatus internal error') { $hasError = $true; break }
    }
    if (-not $hasError) { throw "expected waiterErrors to include the underlying status-read error" }
}

# ----------------------------------------------------------------------------
# Case 5: helper throws + last-result.json present but with loopStatus
# that is neither actionable nor terminal (e.g. retry). Should NOT classify
# as actionable/final; must fall through to 121 with last-result preserved.
# ----------------------------------------------------------------------------
Assert-Case 'helper-throws + non-actionable last-result => 121 (durable read does not over-claim)' {
    $waiterDir = New-TestWaiterDir -StubBody $throwStub
    $runDir = New-TestRunDir
    $script:cleanups += $waiterDir, $runDir

    $retryResult = @{
        loopStatus = 'retry'
        status = 'WAIT'
        event = 'no_event_yet'
        terminal = $false
        stdout = ''
        checkExitCode = 10
    }
    Add-LastResult -RunDir $runDir -Result $retryResult

    $r = Invoke-Waiter -WaiterDir $waiterDir -RunDir $runDir
    if ($r.ExitCode -ne 121) { throw "expected exit 121 (no actionable/final), got $($r.ExitCode). stdout: $($r.Stdout)" }
    $obj = $r.Stdout | ConvertFrom-Json
    if ($obj.waiter.exitReason -ne 'waiter_internal_error') { throw "expected waiter_internal_error, got '$($obj.waiter.exitReason)'" }
    # The non-actionable lastResult must still be surfaced for the agent.
    if (-not $obj.lastResult) { throw "expected lastResult to be preserved in fallback status" }
    if ($obj.lastResult.event -ne 'no_event_yet') { throw "lastResult contents not preserved" }
}

# Cleanup.
foreach ($p in $cleanups) {
    try { Remove-Item -Recurse -Force -LiteralPath $p -ErrorAction SilentlyContinue } catch { }
}

Write-Host ""
Write-Host ("Summary: {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor (& { if ($fail -gt 0) { 'Red' } else { 'Green' } })
if ($fail -gt 0) { exit 1 }
exit 0
