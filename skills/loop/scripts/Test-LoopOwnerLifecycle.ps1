#Requires -Version 7.0
<#
.SYNOPSIS
Regression tests for session-bound detached loop ownership.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$startScript = Join-Path $scriptDir 'Start-LoopDetached.ps1'
$loopScript = Join-Path $scriptDir 'loop.ps1'
$statusScript = Join-Path $scriptDir 'Get-LoopStatus.ps1'
$waiterScript = Join-Path $scriptDir 'Wait-LoopDetached.ps1'

$pass = 0
$fail = 0
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

function New-TestRunDir {
    $dir = Join-Path $env:TEMP ("loop-owner-test-{0:N}" -f ([guid]::NewGuid()))
    $script:cleanups += $dir
    return $dir
}

function ConvertTo-PowerShellSingleQuotedString {
    param([Parameter(Mandatory)][string]$Value)
    "'" + ($Value -replace "'", "''") + "'"
}

function Wait-ForCondition {
    param(
        [Parameter(Mandatory)][scriptblock]$Condition,
        [int]$TimeoutSeconds = 10
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $value = & $Condition
        if ($value) {
            return $value
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return $null
}

function Stop-TestLoopProcess {
    param([Parameter(Mandatory)][string]$RunDir)
    $manifestPath = Join-Path $RunDir 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return
    }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $processId = [int]$manifest.pid
        if ($processId -gt 0 -and $processId -ne $PID) {
            Stop-Process -Id $processId -ErrorAction SilentlyContinue
        }
    } catch {
        return
    }
}

try {
    Assert-Case 'loop.ps1 without owner metadata completes normally' {
        $runDir = New-TestRunDir
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        $lastResultPath = Join-Path $runDir 'last-result.json'
        $eventDir = Join-Path $runDir 'events'

        & pwsh -NoProfile -ExecutionPolicy Bypass -File $loopScript `
            -CheckCommand 'exit 0' `
            -LastResultPath $lastResultPath `
            -EventDir $eventDir `
            -Quiet
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { throw "expected exit 0, got $exitCode" }

        $result = Get-Content -LiteralPath $lastResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($result.loopStatus -ne 'success') { throw "expected success, got '$($result.loopStatus)'" }
    }

    Assert-Case 'detached worker completes while owner process waits' {
        $runDir = New-TestRunDir
        $start = ConvertTo-PowerShellSingleQuotedString -Value $startScript
        $wait = ConvertTo-PowerShellSingleQuotedString -Value $waiterScript
        $quotedRunDir = ConvertTo-PowerShellSingleQuotedString -Value $runDir
        $command = @"
`$manifest = & $start -Name 'owner-live' -RunDir $quotedRunDir -CheckCommand 'exit 0' -IntervalSeconds 1 -TimeoutSeconds 10 -Quiet | ConvertFrom-Json
& $wait -RunDir `$manifest.runDir -PollIntervalSeconds 1 -StatusReadRetries 1
exit `$LASTEXITCODE
"@

        $output = & pwsh -NoProfile -ExecutionPolicy Bypass -Command $command
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { throw "expected waiter exit 0, got $exitCode. Output: $($output | Out-String)" }
        $status = ($output | Out-String).Trim() | ConvertFrom-Json
        if ($status.classification -ne 'final') { throw "expected final classification, got '$($status.classification)'" }
        if ($status.lastResult.loopStatus -ne 'success') { throw "expected success loopStatus, got '$($status.lastResult.loopStatus)'" }
        if (-not $status.ownerRequired) { throw 'expected ownerRequired true' }
        if (-not $status.ownerProcessAlive) { throw 'expected owner process alive while waiter was attached' }
    }

    Assert-Case 'detached worker writes abandoned result after owner exits' {
        $runDir = New-TestRunDir
        $start = ConvertTo-PowerShellSingleQuotedString -Value $startScript
        $quotedRunDir = ConvertTo-PowerShellSingleQuotedString -Value $runDir
        $command = "& $start -Name 'owner-dead' -RunDir $quotedRunDir -CheckCommand 'exit 10' -IntervalSeconds 1 -TimeoutSeconds 20 -RetryExitCode 10 -Quiet | Out-Null"
        & pwsh -NoProfile -ExecutionPolicy Bypass -Command $command
        if ($LASTEXITCODE -ne 0) { throw "launcher failed with exit $LASTEXITCODE" }

        $status = Wait-ForCondition -TimeoutSeconds 10 -Condition {
            if (-not (Test-Path -LiteralPath (Join-Path $runDir 'manifest.json') -PathType Leaf)) {
                return $null
            }
            $current = & $statusScript -RunDir $runDir | ConvertFrom-Json
            if ($current.lastResult -and $current.lastResult.loopStatus -eq 'abandoned') {
                return $current
            }
            return $null
        }
        if (-not $status) {
            Stop-TestLoopProcess -RunDir $runDir
            throw 'expected abandoned last-result before timeout'
        }
        if ($status.classification -ne 'abandoned') { throw "expected abandoned classification, got '$($status.classification)'" }
        if ($status.processAlive) { throw 'expected worker process to exit after abandonment' }
    }

    Assert-Case 'waiter refuses owner-dead run directory without adopting it' {
        $runDir = New-TestRunDir
        $eventsDir = Join-Path $runDir 'events'
        New-Item -ItemType Directory -Path $eventsDir -Force | Out-Null
        $ownerlessPid = 999999
        $currentStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        [ordered]@{
            schemaVersion = 1
            name = 'owner-dead-status'
            runDir = $runDir
            pid = $PID
            processStartTime = $currentStart
            ownerRequired = $true
            ownerProcessId = $ownerlessPid
            ownerProcessStartTime = '2000-01-01T00:00:00.000Z'
            lastResultPath = (Join-Path $runDir 'last-result.json')
            heartbeatPath = (Join-Path $runDir 'heartbeat.json')
            eventDir = $eventsDir
            paramsPath = (Join-Path $runDir 'params.json')
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDir 'manifest.json') -Encoding utf8
        [ordered]@{
            IntervalSeconds = 30
            OwnerRequired = $true
            OwnerProcessId = $ownerlessPid
            OwnerProcessStartTime = '2000-01-01T00:00:00.000Z'
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runDir 'params.json') -Encoding utf8
        [ordered]@{
            schemaVersion = 1
            timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            pid = $PID
            attempt = 1
            phase = 'sleeping'
            nextSleepSeconds = 30
            nextAttemptAfter = (Get-Date).ToUniversalTime().AddSeconds(30).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runDir 'heartbeat.json') -Encoding utf8
        [ordered]@{
            schemaVersion = 1
            timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            pid = $PID
            attempt = 1
            elapsedSeconds = 0
            remainingSeconds = 20
            checkExitCode = 10
            loopStatus = 'retry'
            status = 'WAIT'
            event = 'retryable_exit'
            stdout = ''
            stderr = ''
            terminal = $false
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $runDir 'last-result.json') -Encoding utf8

        $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $waiterScript -RunDir $runDir -PollIntervalSeconds 1 -StatusReadRetries 1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 125) { throw "expected waiter exit 125 for abandoned run, got $exitCode. Output: $($output | Out-String)" }
        $status = ($output | Out-String).Trim() | ConvertFrom-Json
        if ($status.classification -ne 'abandoned') { throw "expected abandoned classification, got '$($status.classification)'" }
        if ($status.ownerProcessAlive) { throw 'expected ownerProcessAlive false' }
        if ($status.waiter.exitReason -ne 'abandoned') { throw "expected waiter exitReason abandoned, got '$($status.waiter.exitReason)'" }
    }
} finally {
    foreach ($path in $cleanups) {
        if (Test-Path -LiteralPath $path -PathType Container) {
            Stop-TestLoopProcess -RunDir $path
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ""
Write-Host ("Summary: {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor (& { if ($fail -gt 0) { 'Red' } else { 'Green' } })
if ($fail -gt 0) { exit 1 }
exit 0
