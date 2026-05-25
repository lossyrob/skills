#Requires -Version 7.0
<#
.SYNOPSIS
Regression tests for Invoke-LoopCleanup.ps1 conservative cleanup behavior.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$cleanupScript = Join-Path $scriptDir 'Invoke-LoopCleanup.ps1'
$runRoot = Join-Path $env:TEMP ("loop-cleanup-test-{0:N}" -f ([guid]::NewGuid()))

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

function New-RunDir {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Result,
        [switch]$Live
    )
    $dir = Join-Path $runRoot $Name
    $events = Join-Path $dir 'events'
    New-Item -ItemType Directory -Force -Path $events | Out-Null
    $pidValue = if ($Live) { $PID } else { 999999 }
    $processStartTime = if ($Live) { (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ') } else { '2000-01-01T00:00:00.000Z' }
    [ordered]@{
        schemaVersion = 1
        pid = $pidValue
        processStartTime = $processStartTime
        eventDir = $events
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dir 'manifest.json') -Encoding utf8

    $event = [ordered]@{
        schemaVersion = 1
        timestamp = '2000-01-01T00:00:00.000Z'
        kind = $Result.kind
        result = [ordered]@{
            schemaVersion = 1
            timestamp = '2000-01-01T00:00:00.000Z'
            attempt = 1
            checkExitCode = $Result.checkExitCode
            loopStatus = $Result.loopStatus
            status = $Result.status
            event = $Result.event
            stdout = ''
            stderr = ''
            terminal = $true
        }
    }
    $event | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $events '20000101T000000000Z-attempt-0000000001-test.json') -Encoding utf8
    return $dir
}

try {
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
    $success = New-RunDir -Name 'old-success' -Result @{ kind = 'success'; loopStatus = 'success'; status = 'SUCCESS'; event = 'condition_satisfied'; checkExitCode = 0 }
    $actionable = New-RunDir -Name 'actionable' -Result @{ kind = 'actionable'; loopStatus = 'actionable'; status = 'ACTION'; event = 'domain_event'; checkExitCode = 31 }
    $live = New-RunDir -Name 'live-success' -Result @{ kind = 'success'; loopStatus = 'success'; status = 'SUCCESS'; event = 'condition_satisfied'; checkExitCode = 0 } -Live

    Assert-Case 'report mode does not delete eligible runs' {
        $report = & pwsh -NoProfile -ExecutionPolicy Bypass -File $cleanupScript -RunRoot $runRoot -RetentionDays 0 -MaxCompletedRuns 0 | ConvertFrom-Json
        if (-not (Test-Path -LiteralPath $success -PathType Container)) { throw 'success run should not be deleted without -Apply' }
        if ($report.eligibleRuns -lt 1) { throw "expected at least one eligible run, got $($report.eligibleRuns)" }
    }

    Assert-Case 'apply deletes only eligible final-success runs' {
        $report = & pwsh -NoProfile -ExecutionPolicy Bypass -File $cleanupScript -RunRoot $runRoot -RetentionDays 0 -MaxCompletedRuns 0 -Apply | ConvertFrom-Json
        if (Test-Path -LiteralPath $success -PathType Container) { throw 'eligible success run should be deleted with -Apply' }
        if (-not (Test-Path -LiteralPath $actionable -PathType Container)) { throw 'actionable run should be retained' }
        if (-not (Test-Path -LiteralPath $live -PathType Container)) { throw 'live run should be retained' }
        if ($report.deletedRuns -ne 1) { throw "expected deletedRuns 1, got $($report.deletedRuns)" }
    }
} finally {
    Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host ("Summary: {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor (& { if ($fail -gt 0) { 'Red' } else { 'Green' } })
if ($fail -gt 0) { exit 1 }
exit 0
