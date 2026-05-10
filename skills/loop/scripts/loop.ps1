#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CheckCommand,

    [string]$ActionCommand = '',
    [string]$AckCommand = '',
    [string]$OnRetryCommand = '',

    [ValidateRange(1, [int]::MaxValue)]
    [int]$IntervalSeconds = 30,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$TimeoutSeconds = 3600,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$MaxTries = 0,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$BackoffFactor = 1,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$MaxIntervalSeconds = 300,

    [ValidateRange(0, 100)]
    [int]$JitterPercent = 0,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$StableForSeconds = 0,

    [int[]]$RetryExitCode = @(),
    [int[]]$StopExitCode = @(126, 127),

    [string]$LockName = '',
    [string]$LogPath = '',

    [switch]$Invert,
    [switch]$Quiet,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$ExitSuccess = 0
$ExitGeneral = 1
$ExitBadArgs = 2
$ExitNoCommand = 3
$ExitTimeout = 124

$script:Mutex = $null
$script:MutexAcquired = $false
$script:TranscriptStarted = $false
$stopwatch = $null

function Write-LoopLog {
    param([string]$Message)
    if (-not $Quiet) {
        $timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        Write-Host "[$timestamp] $Message"
    }
}

function Write-LoopError {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Get-CurrentPowerShellPath {
    try {
        $process = Get-Process -Id $PID
        if ($process.Path) {
            return $process.Path
        }
    } catch {
        # Fall back below.
    }

    if ($PSVersionTable.PSEdition -eq 'Core') {
        return 'pwsh'
    }
    return 'powershell'
}

function Invoke-LoopCommand {
    param([Parameter(Mandatory = $true)][string]$Command)

    $shell = Get-CurrentPowerShellPath
    $wrappedCommand = @"
`$ErrorActionPreference = 'Stop'
try {
    & {
$Command
    }
    if (`$null -ne `$LASTEXITCODE -and `$LASTEXITCODE -ne 0) {
        exit `$LASTEXITCODE
    }
    if (-not `$?) {
        exit 1
    }
    exit 0
} catch {
    [Console]::Error.WriteLine(`$_)
    exit 1
}
"@
    $output = & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $wrappedCommand 2>&1
    $exitCode = $LASTEXITCODE
    if (-not $Quiet -and $output) {
        foreach ($item in $output) {
            if ($item -is [System.Management.Automation.ErrorRecord]) {
                [Console]::Error.WriteLine($item.ToString())
            } else {
                Write-Host $item
            }
        }
    }
    if ($null -eq $exitCode) {
        if ($?) {
            return 0
        }
        return 1
    }
    return [int]$exitCode
}

function Invoke-ActionAndAck {
    param([int]$CheckExitCode)

    if (-not $ActionCommand) {
        return
    }

    $env:LOOP_CHECK_EXIT_CODE = [string]$CheckExitCode

    Write-LoopLog 'running action'
    $actionExit = Invoke-LoopCommand -Command $ActionCommand
    if ($actionExit -ne 0) {
        Write-LoopError "action command failed with exit $actionExit"
        exit $actionExit
    }

    if ($AckCommand) {
        Write-LoopLog 'action succeeded; running ack'
        $ackExit = Invoke-LoopCommand -Command $AckCommand
        if ($ackExit -ne 0) {
            Write-LoopError "ack command failed with exit $ackExit"
            exit $ackExit
        }
    }
}

function Test-CodeInList {
    param(
        [int]$Code,
        [int[]]$List
    )
    if ($null -eq $List -or $List.Count -eq 0) {
        return $false
    }
    return $List -contains $Code
}

function Test-ConditionSucceeded {
    param([int]$ExitCode)
    if ($Invert) {
        return ($ExitCode -ne 0)
    }
    return ($ExitCode -eq 0)
}

function Test-RetryableFailure {
    param([int]$ExitCode)
    if (Test-CodeInList -Code $ExitCode -List $StopExitCode) {
        return $false
    }
    if ($RetryExitCode.Count -gt 0) {
        return (Test-CodeInList -Code $ExitCode -List $RetryExitCode)
    }
    return $true
}

function Get-SleepSeconds {
    param(
        [int]$CurrentInterval,
        [int]$RemainingSeconds
    )

    $sleepSeconds = $CurrentInterval
    if ($JitterPercent -gt 0) {
        $jitterMax = [Math]::Floor($CurrentInterval * $JitterPercent / 100.0)
        if ($jitterMax -gt 0) {
            $sleepSeconds += Get-Random -Minimum 0 -Maximum ([int]$jitterMax + 1)
        }
    }
    if ($TimeoutSeconds -gt 0 -and $RemainingSeconds -gt 0 -and $sleepSeconds -gt $RemainingSeconds) {
        $sleepSeconds = $RemainingSeconds
    }
    return [int]$sleepSeconds
}

function Start-LoopTranscript {
    if ($LogPath) {
        Start-Transcript -Path $LogPath -Append | Out-Null
        $script:TranscriptStarted = $true
    }
}

function Acquire-LoopLock {
    if (-not $LockName) {
        return
    }

    $safeName = ($LockName -replace '[^A-Za-z0-9_.-]', '_')
    $mutexName = "Local\CopilotLoop-$safeName"
    $script:Mutex = [System.Threading.Mutex]::new($false, $mutexName)
    $script:MutexAcquired = $script:Mutex.WaitOne(0)
    if (-not $script:MutexAcquired) {
        Write-LoopError "another loop is already running for lock '$LockName'"
        exit $ExitGeneral
    }
}

function Release-LoopResources {
    if ($script:TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        } catch {
            Write-Warning "failed to stop transcript: $_"
        }
    }

    if ($script:Mutex) {
        try {
            if ($script:MutexAcquired) {
                $script:Mutex.ReleaseMutex()
            }
        } finally {
            $script:Mutex.Dispose()
        }
    }
}

function Show-DryRun {
    [ordered]@{
        check_command        = $CheckCommand
        action_command       = $ActionCommand
        ack_command          = $AckCommand
        on_retry_command     = $OnRetryCommand
        interval_seconds     = $IntervalSeconds
        timeout_seconds      = $TimeoutSeconds
        max_tries            = $MaxTries
        backoff_factor       = $BackoffFactor
        max_interval_seconds = $MaxIntervalSeconds
        jitter_percent       = $JitterPercent
        stable_for_seconds   = $StableForSeconds
        invert               = [bool]$Invert
        retry_exit_codes     = $RetryExitCode
        stop_exit_codes      = $StopExitCode
        lock_name            = $LockName
    } | ConvertTo-Json -Depth 3
}

try {
    if ($AckCommand -and -not $ActionCommand) {
        Write-LoopError '-AckCommand requires -ActionCommand'
        exit $ExitBadArgs
    }

    Start-LoopTranscript
    Acquire-LoopLock

    if ($DryRun) {
        Show-DryRun
        exit $ExitSuccess
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $attempt = 0
    $currentInterval = $IntervalSeconds

    while ($true) {
        $attempt++
        $elapsed = [int]$stopwatch.Elapsed.TotalSeconds
        $remaining = 0
        if ($TimeoutSeconds -gt 0) {
            $remaining = [Math]::Max(0, $TimeoutSeconds - $elapsed)
        }

        Remove-Item env:LOOP_CHECK_EXIT_CODE -ErrorAction SilentlyContinue
        $env:LOOP_ATTEMPT = [string]$attempt
        $env:LOOP_ELAPSED_SECONDS = [string]$elapsed
        $env:LOOP_REMAINING_SECONDS = [string]$remaining

        Write-LoopLog "attempt ${attempt}: running check"
        $checkExit = Invoke-LoopCommand -Command $CheckCommand

        if (Test-ConditionSucceeded -ExitCode $checkExit) {
            if ($StableForSeconds -gt 0) {
                Write-LoopLog "condition met; waiting ${StableForSeconds}s stability window"
                Start-Sleep -Seconds $StableForSeconds
                Remove-Item env:LOOP_CHECK_EXIT_CODE -ErrorAction SilentlyContinue
                $stableExit = Invoke-LoopCommand -Command $CheckCommand
                if (-not (Test-ConditionSucceeded -ExitCode $stableExit)) {
                    Write-LoopLog "condition did not remain stable; continuing"
                    $checkExit = $stableExit
                } else {
                    Invoke-ActionAndAck -CheckExitCode $checkExit
                    exit $ExitSuccess
                }
            } else {
                Invoke-ActionAndAck -CheckExitCode $checkExit
                exit $ExitSuccess
            }
        }

        if (-not (Test-RetryableFailure -ExitCode $checkExit)) {
            if ($checkExit -eq 126 -or $checkExit -eq 127) {
                Write-LoopError "check command failed with fatal exit $checkExit"
                exit $ExitNoCommand
            }
            if ($ActionCommand -and (Test-CodeInList -Code $checkExit -List $StopExitCode)) {
                Write-LoopLog "check returned actionable exit $checkExit"
                Invoke-ActionAndAck -CheckExitCode $checkExit
                exit $ExitSuccess
            }
            Write-LoopError "check stopped with non-retryable exit $checkExit"
            exit $checkExit
        }

        $elapsed = [int]$stopwatch.Elapsed.TotalSeconds
        if ($TimeoutSeconds -gt 0 -and $elapsed -ge $TimeoutSeconds) {
            Write-LoopError "timed out after ${elapsed}s (${attempt} attempt(s))"
            exit $ExitTimeout
        }
        if ($MaxTries -gt 0 -and $attempt -ge $MaxTries) {
            Write-LoopError "max tries reached after ${attempt} attempt(s)"
            exit $ExitTimeout
        }

        if ($OnRetryCommand) {
            $env:LOOP_CHECK_EXIT_CODE = [string]$checkExit
            Write-LoopLog 'running on-retry hook'
            $retryExit = Invoke-LoopCommand -Command $OnRetryCommand
            if ($retryExit -ne 0) {
                Write-LoopError "on-retry command failed with exit $retryExit"
                exit $ExitGeneral
            }
        }

        $elapsed = [int]$stopwatch.Elapsed.TotalSeconds
        if ($TimeoutSeconds -gt 0) {
            $remaining = [Math]::Max(0, $TimeoutSeconds - $elapsed)
        } else {
            $remaining = 0
        }

        $sleepSeconds = Get-SleepSeconds -CurrentInterval $currentInterval -RemainingSeconds $remaining
        Write-LoopLog "check exited $checkExit; sleeping ${sleepSeconds}s"
        if ($sleepSeconds -gt 0) {
            Start-Sleep -Seconds $sleepSeconds
        }

        if ($BackoffFactor -gt 1) {
            $currentInterval = [Math]::Min($currentInterval * $BackoffFactor, $MaxIntervalSeconds)
        }
    }
} finally {
    if ($null -ne $stopwatch) {
        $stopwatch.Stop()
    }
    Release-LoopResources
}
