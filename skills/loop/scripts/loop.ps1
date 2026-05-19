#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CheckCommand = '',

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
    [string]$LastResultPath = '',
    [string]$HeartbeatPath = '',
    [string]$EventDir = '',
    [string]$ParamsFile = '',

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

function Get-UtcTimestamp {
    return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
}

function ConvertTo-PlainText {
    param([object[]]$Items)
    if (-not $Items -or $Items.Count -eq 0) {
        return ''
    }
    return (($Items | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
}

function Write-AtomicText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    $directory = Split-Path -Parent $Path
    if (-not $directory) {
        $directory = (Get-Location).ProviderPath
        $Path = Join-Path $directory $Path
    }
    New-Item -ItemType Directory -Force -Path $directory | Out-Null

    $leaf = Split-Path -Leaf $Path
    $tmp = Join-Path $directory ('.{0}.{1}.tmp' -f $leaf, ([guid]::NewGuid().ToString('N')))
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($tmp, $Text, $utf8NoBom)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $backup = Join-Path $directory ('.{0}.{1}.bak' -f $leaf, ([guid]::NewGuid().ToString('N')))
        [System.IO.File]::Replace($tmp, $Path, $backup)
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    } else {
        [System.IO.File]::Move($tmp, $Path)
    }
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )
    $json = $Value | ConvertTo-Json -Depth 12
    Write-AtomicText -Path $Path -Text ($json + [Environment]::NewLine)
}

function Get-JsonProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }
    return $null
}

function Import-ParamsFile {
    if (-not $ParamsFile) {
        return
    }
    $resolved = Resolve-Path -LiteralPath $ParamsFile -ErrorAction Stop
    $params = Get-Content -LiteralPath $resolved.ProviderPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $value = Get-JsonProperty -Object $params -Name 'CheckCommand'
    if ($null -ne $value) { $script:CheckCommand = [string]$value }
    $value = Get-JsonProperty -Object $params -Name 'ActionCommand'
    if ($null -ne $value) { $script:ActionCommand = [string]$value }
    $value = Get-JsonProperty -Object $params -Name 'AckCommand'
    if ($null -ne $value) { $script:AckCommand = [string]$value }
    $value = Get-JsonProperty -Object $params -Name 'OnRetryCommand'
    if ($null -ne $value) { $script:OnRetryCommand = [string]$value }
    $value = Get-JsonProperty -Object $params -Name 'IntervalSeconds'
    if ($null -ne $value) { $script:IntervalSeconds = [int]$value }
    $value = Get-JsonProperty -Object $params -Name 'TimeoutSeconds'
    if ($null -ne $value) { $script:TimeoutSeconds = [int]$value }
    $value = Get-JsonProperty -Object $params -Name 'MaxTries'
    if ($null -ne $value) { $script:MaxTries = [int]$value }
    $value = Get-JsonProperty -Object $params -Name 'BackoffFactor'
    if ($null -ne $value) { $script:BackoffFactor = [int]$value }
    $value = Get-JsonProperty -Object $params -Name 'MaxIntervalSeconds'
    if ($null -ne $value) { $script:MaxIntervalSeconds = [int]$value }
    $value = Get-JsonProperty -Object $params -Name 'JitterPercent'
    if ($null -ne $value) { $script:JitterPercent = [int]$value }
    $value = Get-JsonProperty -Object $params -Name 'StableForSeconds'
    if ($null -ne $value) { $script:StableForSeconds = [int]$value }
    $value = Get-JsonProperty -Object $params -Name 'RetryExitCode'
    if ($null -ne $value) { $script:RetryExitCode = @($value | ForEach-Object { [int]$_ }) }
    $value = Get-JsonProperty -Object $params -Name 'StopExitCode'
    if ($null -ne $value) { $script:StopExitCode = @($value | ForEach-Object { [int]$_ }) }
    $value = Get-JsonProperty -Object $params -Name 'LockName'
    if ($null -ne $value) { $script:LockName = [string]$value }
    $value = Get-JsonProperty -Object $params -Name 'LogPath'
    if ($null -ne $value) { $script:LogPath = [string]$value }
    $value = Get-JsonProperty -Object $params -Name 'LastResultPath'
    if ($null -ne $value) { $script:LastResultPath = [string]$value }
    $value = Get-JsonProperty -Object $params -Name 'HeartbeatPath'
    if ($null -ne $value) { $script:HeartbeatPath = [string]$value }
    $value = Get-JsonProperty -Object $params -Name 'EventDir'
    if ($null -ne $value) { $script:EventDir = [string]$value }
    $value = Get-JsonProperty -Object $params -Name 'Invert'
    if ($null -ne $value) { $script:Invert = [System.Management.Automation.SwitchParameter]::new([bool]$value) }
    $value = Get-JsonProperty -Object $params -Name 'Quiet'
    if ($null -ne $value) { $script:Quiet = [System.Management.Automation.SwitchParameter]::new([bool]$value) }
    $value = Get-JsonProperty -Object $params -Name 'DryRun'
    if ($null -ne $value) { $script:DryRun = [System.Management.Automation.SwitchParameter]::new([bool]$value) }
}

function Write-LoopHeartbeat {
    param(
        [Parameter(Mandatory = $true)][string]$Phase,
        [int]$Attempt = 0,
        [int]$NextSleepSeconds = 0,
        [AllowNull()][string]$NextAttemptAfter = $null
    )
    if (-not $HeartbeatPath) {
        return
    }
    $heartbeat = [ordered]@{
        schemaVersion = 1
        timestamp = Get-UtcTimestamp
        pid = $PID
        attempt = $Attempt
        phase = $Phase
        nextSleepSeconds = $NextSleepSeconds
        nextAttemptAfter = $NextAttemptAfter
    }
    Write-AtomicJson -Path $HeartbeatPath -Value $heartbeat
}

function Get-CheckPayload {
    param([string]$Stdout)
    if ([string]::IsNullOrWhiteSpace($Stdout)) {
        return $null
    }
    $trimmed = $Stdout.Trim()
    if (-not $trimmed.StartsWith('{')) {
        return $null
    }
    try {
        return $trimmed | ConvertFrom-Json
    } catch {
        return $null
    }
}

function New-LoopResult {
    param(
        [Parameter(Mandatory = $true)][int]$Attempt,
        [Parameter(Mandatory = $true)][int]$ElapsedSeconds,
        [Parameter(Mandatory = $true)][int]$RemainingSeconds,
        [Parameter(Mandatory = $true)][object]$CheckResult,
        [Parameter(Mandatory = $true)][string]$LoopStatus,
        [Parameter(Mandatory = $true)][string]$DefaultStatus,
        [Parameter(Mandatory = $true)][string]$DefaultEvent,
        [bool]$Terminal = $false,
        [AllowNull()][int]$NextSleepSeconds = $null,
        [AllowNull()][string]$NextAttemptAfter = $null
    )
    $payload = Get-CheckPayload -Stdout $CheckResult.Stdout
    $status = $DefaultStatus
    $event = $DefaultEvent
    if ($payload) {
        $payloadStatus = Get-JsonProperty -Object $payload -Name 'status'
        if ($null -ne $payloadStatus -and -not [string]::IsNullOrWhiteSpace([string]$payloadStatus)) {
            $status = [string]$payloadStatus
        }
        $payloadEvent = Get-JsonProperty -Object $payload -Name 'event'
        if ($null -ne $payloadEvent -and -not [string]::IsNullOrWhiteSpace([string]$payloadEvent)) {
            $event = [string]$payloadEvent
        }
    }
    return [ordered]@{
        schemaVersion = 1
        timestamp = Get-UtcTimestamp
        pid = $PID
        attempt = $Attempt
        elapsedSeconds = $ElapsedSeconds
        remainingSeconds = $RemainingSeconds
        checkExitCode = [int]$CheckResult.ExitCode
        loopStatus = $LoopStatus
        status = $status
        event = $event
        stdout = [string]$CheckResult.Stdout
        stderr = [string]$CheckResult.Stderr
        nextSleepSeconds = $NextSleepSeconds
        nextAttemptAfter = $NextAttemptAfter
        terminal = [bool]$Terminal
    }
}

function Write-LoopResult {
    param([Parameter(Mandatory = $true)][object]$Result)
    if ($LastResultPath) {
        Write-AtomicJson -Path $LastResultPath -Value $Result
    }
}

function Write-LoopEvent {
    param(
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][object]$Result
    )
    if (-not $EventDir) {
        return
    }
    New-Item -ItemType Directory -Force -Path $EventDir | Out-Null
    $safeKind = $Kind -replace '[^A-Za-z0-9_.-]', '_'
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
    $attemptNumber = 0
    if ($null -ne $Result.PSObject.Properties['attempt']) {
        $attemptNumber = [int]$Result.attempt
    }
    $path = Join-Path $EventDir ("{0}-attempt-{1:D10}-{2}-{3}.json" -f $timestamp, $attemptNumber, $safeKind, ([guid]::NewGuid().ToString('N')))
    $event = [ordered]@{
        schemaVersion = 1
        timestamp = Get-UtcTimestamp
        kind = $Kind
        pid = $PID
        result = $Result
    }
    Write-AtomicJson -Path $path -Value $event
}

function Get-LoopAttemptFromEnv {
    if ($env:LOOP_ATTEMPT) {
        return [int]$env:LOOP_ATTEMPT
    }
    return 0
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
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $stdoutText = ''
    $stderrText = ''
    $exitCode = $null
    try {
        $stdoutItems = & $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $wrappedCommand 2> $stderrPath
        $exitCode = $LASTEXITCODE
        $stdoutText = ConvertTo-PlainText -Items @($stdoutItems)
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            $stderrText = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
        }
        if ($null -eq $stderrText) {
            $stderrText = ''
        }
    } finally {
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
    if (-not $Quiet) {
        if ($stdoutText) {
            Write-Host $stdoutText
        }
        if ($stderrText) {
            [Console]::Error.Write($stderrText)
        }
    }
    if ($null -eq $exitCode) {
        if ($?) {
            $exitCode = 0
        } else {
            $exitCode = 1
        }
    }
    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Stdout = $stdoutText
        Stderr = $stderrText
    }
}

function Invoke-ActionAndAck {
    param([int]$CheckExitCode)

    if (-not $ActionCommand) {
        return
    }

    $env:LOOP_CHECK_EXIT_CODE = [string]$CheckExitCode

    Write-LoopLog 'running action'
    Write-LoopHeartbeat -Phase 'action' -Attempt (Get-LoopAttemptFromEnv)
    $actionResult = Invoke-LoopCommand -Command $ActionCommand
    if ($actionResult.ExitCode -ne 0) {
        Write-LoopError "action command failed with exit $($actionResult.ExitCode)"
        $result = [ordered]@{
            schemaVersion = 1
            timestamp = Get-UtcTimestamp
            pid = $PID
            attempt = Get-LoopAttemptFromEnv
            loopStatus = 'action_failed'
            status = 'ERROR'
            event = 'action_failed'
            checkExitCode = $CheckExitCode
            actionExitCode = [int]$actionResult.ExitCode
            stdout = [string]$actionResult.Stdout
            stderr = [string]$actionResult.Stderr
            terminal = $true
        }
        Write-LoopResult -Result $result
        Write-LoopEvent -Kind 'action_failed' -Result $result
        exit $actionResult.ExitCode
    }

    if ($AckCommand) {
        Write-LoopLog 'action succeeded; running ack'
        Write-LoopHeartbeat -Phase 'ack' -Attempt (Get-LoopAttemptFromEnv)
        $ackResult = Invoke-LoopCommand -Command $AckCommand
        if ($ackResult.ExitCode -ne 0) {
            Write-LoopError "ack command failed with exit $($ackResult.ExitCode)"
            $result = [ordered]@{
                schemaVersion = 1
                timestamp = Get-UtcTimestamp
                pid = $PID
                attempt = Get-LoopAttemptFromEnv
                loopStatus = 'ack_failed'
                status = 'ERROR'
                event = 'ack_failed'
                checkExitCode = $CheckExitCode
                ackExitCode = [int]$ackResult.ExitCode
                stdout = [string]$ackResult.Stdout
                stderr = [string]$ackResult.Stderr
                terminal = $true
            }
            Write-LoopResult -Result $result
            Write-LoopEvent -Kind 'ack_failed' -Result $result
            exit $ackResult.ExitCode
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
        log_path             = $LogPath
        last_result_path     = $LastResultPath
        heartbeat_path       = $HeartbeatPath
        event_dir            = $EventDir
        params_file          = $ParamsFile
    } | ConvertTo-Json -Depth 3
}

try {
    Import-ParamsFile
    if (-not $CheckCommand) {
        Write-LoopError '-CheckCommand is required'
        exit $ExitBadArgs
    }
    if ($AckCommand -and -not $ActionCommand) {
        Write-LoopError '-AckCommand requires -ActionCommand'
        exit $ExitBadArgs
    }
    if ($IntervalSeconds -lt 1 -or $TimeoutSeconds -lt 0 -or $MaxTries -lt 0 -or $BackoffFactor -lt 1 -or $MaxIntervalSeconds -lt 1 -or $JitterPercent -lt 0 -or $JitterPercent -gt 100 -or $StableForSeconds -lt 0) {
        Write-LoopError 'invalid numeric loop parameter'
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
        Write-LoopHeartbeat -Phase 'checking' -Attempt $attempt
        $checkResult = Invoke-LoopCommand -Command $CheckCommand
        $checkExit = [int]$checkResult.ExitCode

        if (Test-ConditionSucceeded -ExitCode $checkExit) {
            if ($StableForSeconds -gt 0) {
                $nextAttemptAfter = (Get-Date).ToUniversalTime().AddSeconds($StableForSeconds).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                $result = New-LoopResult -Attempt $attempt -ElapsedSeconds $elapsed -RemainingSeconds $remaining -CheckResult $checkResult -LoopStatus 'stable_wait' -DefaultStatus 'WAIT' -DefaultEvent 'stability_window' -NextSleepSeconds $StableForSeconds -NextAttemptAfter $nextAttemptAfter
                Write-LoopResult -Result $result
                Write-LoopLog "condition met; waiting ${StableForSeconds}s stability window"
                Write-LoopHeartbeat -Phase 'stable_sleep' -Attempt $attempt -NextSleepSeconds $StableForSeconds -NextAttemptAfter $nextAttemptAfter
                Start-Sleep -Seconds $StableForSeconds

                $attempt++
                Remove-Item env:LOOP_CHECK_EXIT_CODE -ErrorAction SilentlyContinue
                $env:LOOP_ATTEMPT = [string]$attempt
                $env:LOOP_ELAPSED_SECONDS = [string]([int]$stopwatch.Elapsed.TotalSeconds)
                $env:LOOP_REMAINING_SECONDS = [string]$remaining
                Write-LoopHeartbeat -Phase 'stable_checking' -Attempt $attempt
                $stableResult = Invoke-LoopCommand -Command $CheckCommand
                $stableExit = [int]$stableResult.ExitCode
                if (-not (Test-ConditionSucceeded -ExitCode $stableExit)) {
                    Write-LoopLog "condition did not remain stable; continuing"
                    $checkResult = $stableResult
                    $checkExit = $stableExit
                } else {
                    $result = New-LoopResult -Attempt $attempt -ElapsedSeconds ([int]$stopwatch.Elapsed.TotalSeconds) -RemainingSeconds $remaining -CheckResult $stableResult -LoopStatus 'success' -DefaultStatus 'SUCCESS' -DefaultEvent 'condition_satisfied' -Terminal $true
                    Write-LoopResult -Result $result
                    Write-LoopEvent -Kind 'success' -Result $result
                    Invoke-ActionAndAck -CheckExitCode $stableExit
                    exit $ExitSuccess
                }
            } else {
                $result = New-LoopResult -Attempt $attempt -ElapsedSeconds $elapsed -RemainingSeconds $remaining -CheckResult $checkResult -LoopStatus 'success' -DefaultStatus 'SUCCESS' -DefaultEvent 'condition_satisfied' -Terminal $true
                Write-LoopResult -Result $result
                Write-LoopEvent -Kind 'success' -Result $result
                Invoke-ActionAndAck -CheckExitCode $checkExit
                exit $ExitSuccess
            }
        }

        if (-not (Test-RetryableFailure -ExitCode $checkExit)) {
            if ($checkExit -eq 126 -or $checkExit -eq 127) {
                Write-LoopError "check command failed with fatal exit $checkExit"
                $result = New-LoopResult -Attempt $attempt -ElapsedSeconds $elapsed -RemainingSeconds $remaining -CheckResult $checkResult -LoopStatus 'fatal' -DefaultStatus 'ERROR' -DefaultEvent 'check_not_executable' -Terminal $true
                Write-LoopResult -Result $result
                Write-LoopEvent -Kind 'fatal' -Result $result
                exit $ExitNoCommand
            }
            if (Test-CodeInList -Code $checkExit -List $StopExitCode) {
                Write-LoopLog "check returned actionable exit $checkExit"
                $result = New-LoopResult -Attempt $attempt -ElapsedSeconds $elapsed -RemainingSeconds $remaining -CheckResult $checkResult -LoopStatus 'actionable' -DefaultStatus 'ACTION' -DefaultEvent 'stop_exit_code' -Terminal $true
                Write-LoopResult -Result $result
                Write-LoopEvent -Kind 'actionable' -Result $result
                if ($ActionCommand) {
                    Invoke-ActionAndAck -CheckExitCode $checkExit
                    exit $ExitSuccess
                }
                exit $checkExit
            }
            Write-LoopError "check stopped with non-retryable exit $checkExit"
            $result = New-LoopResult -Attempt $attempt -ElapsedSeconds $elapsed -RemainingSeconds $remaining -CheckResult $checkResult -LoopStatus 'stopped' -DefaultStatus 'STOP' -DefaultEvent 'non_retryable_exit' -Terminal $true
            Write-LoopResult -Result $result
            Write-LoopEvent -Kind 'stopped' -Result $result
            exit $checkExit
        }

        $elapsed = [int]$stopwatch.Elapsed.TotalSeconds
        if ($TimeoutSeconds -gt 0 -and $elapsed -ge $TimeoutSeconds) {
            Write-LoopError "timed out after ${elapsed}s (${attempt} attempt(s))"
            $result = New-LoopResult -Attempt $attempt -ElapsedSeconds $elapsed -RemainingSeconds 0 -CheckResult $checkResult -LoopStatus 'timeout' -DefaultStatus 'TIMEOUT' -DefaultEvent 'timeout' -Terminal $true
            Write-LoopResult -Result $result
            Write-LoopEvent -Kind 'timeout' -Result $result
            exit $ExitTimeout
        }
        if ($MaxTries -gt 0 -and $attempt -ge $MaxTries) {
            Write-LoopError "max tries reached after ${attempt} attempt(s)"
            $result = New-LoopResult -Attempt $attempt -ElapsedSeconds $elapsed -RemainingSeconds $remaining -CheckResult $checkResult -LoopStatus 'timeout' -DefaultStatus 'TIMEOUT' -DefaultEvent 'max_tries' -Terminal $true
            Write-LoopResult -Result $result
            Write-LoopEvent -Kind 'max_tries' -Result $result
            exit $ExitTimeout
        }

        if ($OnRetryCommand) {
            $env:LOOP_CHECK_EXIT_CODE = [string]$checkExit
            Write-LoopLog 'running on-retry hook'
            Write-LoopHeartbeat -Phase 'on_retry' -Attempt $attempt
            $retryResult = Invoke-LoopCommand -Command $OnRetryCommand
            if ($retryResult.ExitCode -ne 0) {
                Write-LoopError "on-retry command failed with exit $($retryResult.ExitCode)"
                $result = [ordered]@{
                    schemaVersion = 1
                    timestamp = Get-UtcTimestamp
                    pid = $PID
                    attempt = $attempt
                    loopStatus = 'on_retry_failed'
                    status = 'ERROR'
                    event = 'on_retry_failed'
                    checkExitCode = $checkExit
                    onRetryExitCode = [int]$retryResult.ExitCode
                    stdout = [string]$retryResult.Stdout
                    stderr = [string]$retryResult.Stderr
                    terminal = $true
                }
                Write-LoopResult -Result $result
                Write-LoopEvent -Kind 'on_retry_failed' -Result $result
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
        $nextAttemptAfter = (Get-Date).ToUniversalTime().AddSeconds($sleepSeconds).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        $result = New-LoopResult -Attempt $attempt -ElapsedSeconds $elapsed -RemainingSeconds $remaining -CheckResult $checkResult -LoopStatus 'retry' -DefaultStatus 'WAIT' -DefaultEvent 'retryable_exit' -NextSleepSeconds $sleepSeconds -NextAttemptAfter $nextAttemptAfter
        Write-LoopResult -Result $result
        Write-LoopLog "check exited $checkExit; sleeping ${sleepSeconds}s"
        Write-LoopHeartbeat -Phase 'sleeping' -Attempt $attempt -NextSleepSeconds $sleepSeconds -NextAttemptAfter $nextAttemptAfter
        if ($sleepSeconds -gt 0) {
            Start-Sleep -Seconds $sleepSeconds
        }
        Write-LoopHeartbeat -Phase 'awake' -Attempt $attempt

        if ($BackoffFactor -gt 1) {
            $currentInterval = [Math]::Min($currentInterval * $BackoffFactor, $MaxIntervalSeconds)
        }
    }
} catch {
    $message = $_.Exception.Message
    Write-LoopError "loop crashed: $message"
    try {
        $result = [ordered]@{
            schemaVersion = 1
            timestamp = Get-UtcTimestamp
            pid = $PID
            attempt = if ($env:LOOP_ATTEMPT) { [int]$env:LOOP_ATTEMPT } else { 0 }
            loopStatus = 'crashed'
            status = 'ERROR'
            event = 'loop_crashed'
            error = $message
            terminal = $true
        }
        Write-LoopResult -Result $result
        Write-LoopEvent -Kind 'crashed' -Result $result
    } catch {
        # Preserve the original crash path even if diagnostic writes fail.
    }
    exit $ExitGeneral
} finally {
    if ($null -ne $stopwatch) {
        $stopwatch.Stop()
    }
    Release-LoopResources
}
