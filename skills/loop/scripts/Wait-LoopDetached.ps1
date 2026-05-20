#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RunDir,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$PollIntervalSeconds = 10,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$TimeoutSeconds = 0,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$GraceSeconds = 30,

    [ValidateSet('final', 'actionable', 'crashed')]
    [string[]]$TerminalClassification = @('final', 'actionable', 'crashed'),

    [ValidateRange(0, [int]::MaxValue)]
    [int]$StalledPollsToExit = 3,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$ConfirmCrashedDelaySeconds = 2,

    [ValidateRange(1, 10)]
    [int]$StatusReadRetries = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExitGeneral = 1
$ExitBadArgs = 2
$ExitNoCommand = 3
$ExitWaiterTimeout = 122
$ExitLoopTimeout = 124
$ExitStalled = 125

function Write-WaiterError {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
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

function Get-JsonProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }
    return $null
}

function ConvertTo-PositiveInt {
    param(
        [AllowNull()][object]$Value,
        [int]$Default = 0
    )
    if ($null -eq $Value) {
        return $Default
    }
    $text = ([string]$Value).Trim()
    if (-not $text) {
        return $Default
    }
    $parsed = 0
    if ([int]::TryParse($text, [ref]$parsed) -and $parsed -gt 0) {
        return $parsed
    }
    return $Default
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-StatusResult {
    param([AllowNull()][object]$Status)
    if ($null -eq $Status) {
        return $null
    }
    $latestEvent = Get-JsonProperty -Object $Status -Name 'latestEvent'
    $eventResult = Get-JsonProperty -Object $latestEvent -Name 'result'
    if ($null -ne $eventResult) {
        return $eventResult
    }
    return Get-JsonProperty -Object $Status -Name 'lastResult'
}

function Test-DetachedActionConfigured {
    param([Parameter(Mandatory = $true)][string]$ResolvedRunDir)
    $paramsPath = Join-Path $ResolvedRunDir 'params.json'
    try {
        $params = Read-JsonFile -Path $paramsPath
        $actionCommand = Get-JsonProperty -Object $params -Name 'ActionCommand'
        return -not [string]::IsNullOrWhiteSpace([string]$actionCommand)
    } catch {
        return $false
    }
}

function Get-WaiterExitCode {
    param(
        [Parameter(Mandatory = $true)][object]$Status,
        [Parameter(Mandatory = $true)][string]$Classification
    )

    $result = Get-StatusResult -Status $Status
    $loopStatus = ([string](Get-JsonProperty -Object $result -Name 'loopStatus')).ToLowerInvariant()
    $checkExitCode = ConvertTo-PositiveInt -Value (Get-JsonProperty -Object $result -Name 'checkExitCode') -Default 0

    switch ($Classification.ToLowerInvariant()) {
        'actionable' {
            if ($checkExitCode -gt 0) { return $checkExitCode }
            return $ExitGeneral
        }
        'stalled' {
            return $ExitStalled
        }
        'crashed' {
            return $ExitGeneral
        }
        'final' {
            switch ($loopStatus) {
                'success' { return 0 }
                'action_completed' { return 0 }
                'timeout' { return $ExitLoopTimeout }
                'fatal' { return $ExitNoCommand }
                'action_failed' {
                    $actionExitCode = ConvertTo-PositiveInt -Value (Get-JsonProperty -Object $result -Name 'actionExitCode') -Default 0
                    if ($actionExitCode -gt 0) { return $actionExitCode }
                    return $ExitGeneral
                }
                'ack_failed' {
                    $ackExitCode = ConvertTo-PositiveInt -Value (Get-JsonProperty -Object $result -Name 'ackExitCode') -Default 0
                    if ($ackExitCode -gt 0) { return $ackExitCode }
                    return $ExitGeneral
                }
                'stopped' {
                    if ($checkExitCode -gt 0) { return $checkExitCode }
                    return $ExitGeneral
                }
                'crashed' { return $ExitGeneral }
                'on_retry_failed' { return $ExitGeneral }
                default {
                    $terminal = [bool](Get-JsonProperty -Object $result -Name 'terminal')
                    if ($terminal -and $checkExitCode -eq 0) { return 0 }
                    if ($checkExitCode -gt 0) { return $checkExitCode }
                    return $ExitGeneral
                }
            }
        }
        default {
            return $ExitGeneral
        }
    }
}

function Add-WaiterMetadata {
    param(
        [Parameter(Mandatory = $true)][object]$Status,
        [Parameter(Mandatory = $true)][datetime]$StartedAtUtc,
        [Parameter(Mandatory = $true)][int]$PollCount,
        [Parameter(Mandatory = $true)][string]$ExitReason,
        [switch]$TimedOut,
        [int]$ConsecutiveStalledPolls = 0
    )
    $now = (Get-Date).ToUniversalTime()
    $metadata = [ordered]@{
        schemaVersion = 1
        source = 'Wait-LoopDetached.ps1'
        timestamp = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        pollCount = $PollCount
        waitedSeconds = [int]($now - $StartedAtUtc).TotalSeconds
        pollIntervalSeconds = $PollIntervalSeconds
        timeoutSeconds = $TimeoutSeconds
        graceSeconds = $GraceSeconds
        terminalClassification = @($TerminalClassification)
        stalledPollsToExit = $StalledPollsToExit
        consecutiveStalledPolls = $ConsecutiveStalledPolls
        timedOut = [bool]$TimedOut
        exitReason = $ExitReason
    }
    $Status | Add-Member -NotePropertyName waiter -NotePropertyValue ([pscustomobject]$metadata) -Force
    return $Status
}

function Invoke-StatusRead {
    param(
        [Parameter(Mandatory = $true)][string]$StatusScript,
        [Parameter(Mandatory = $true)][string]$ResolvedRunDir
    )

    $errors = @()
    for ($attempt = 1; $attempt -le $StatusReadRetries; $attempt++) {
        $stderrPath = [System.IO.Path]::GetTempFileName()
        try {
            $outputItems = & $StatusScript -RunDir $ResolvedRunDir -GraceSeconds $GraceSeconds 2> $stderrPath
            $stdoutText = ConvertTo-PlainText -Items @($outputItems)
            $stderrText = ''
            if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
                $stderrText = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
            }
            if ($null -eq $stderrText) {
                $stderrText = ''
            }
            if ($stderrText.Trim()) {
                $errors += $stderrText.Trim()
            }
            if ([string]::IsNullOrWhiteSpace($stdoutText)) {
                throw 'Get-LoopStatus.ps1 produced no JSON output'
            }
            return $stdoutText | ConvertFrom-Json
        } catch {
            $errors += $_.Exception.Message
            if ($attempt -lt $StatusReadRetries) {
                Start-Sleep -Milliseconds ([Math]::Min(1000, 150 * $attempt))
            }
        } finally {
            Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
        }
    }
    throw ("Could not read detached loop status after {0} attempt(s): {1}" -f $StatusReadRetries, (($errors | Select-Object -Unique) -join '; '))
}

function Write-StatusAndExit {
    param(
        [Parameter(Mandatory = $true)][object]$Status,
        [Parameter(Mandatory = $true)][int]$ExitCode
    )
    $Status | ConvertTo-Json -Depth 16
    exit $ExitCode
}

$statusScript = Join-Path $PSScriptRoot 'Get-LoopStatus.ps1'
if (-not (Test-Path -LiteralPath $statusScript -PathType Leaf)) {
    Write-WaiterError "Missing detached loop status script: $statusScript"
    exit $ExitNoCommand
}

try {
    $resolvedRunDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunDir)
    $resolvedRunDir = [System.IO.Path]::GetFullPath($resolvedRunDir)
} catch {
    Write-WaiterError "Invalid run directory '$RunDir': $($_.Exception.Message)"
    exit $ExitBadArgs
}

$startedAt = (Get-Date).ToUniversalTime()
$pollCount = 0
$consecutiveStalledPolls = 0
$lastStatus = $null
$actionCommandConfigured = Test-DetachedActionConfigured -ResolvedRunDir $resolvedRunDir

while ($true) {
    try {
        $pollCount++
        $lastStatus = Invoke-StatusRead -StatusScript $statusScript -ResolvedRunDir $resolvedRunDir
        $classification = ([string](Get-JsonProperty -Object $lastStatus -Name 'classification')).ToLowerInvariant()
        $processAlive = [bool](Get-JsonProperty -Object $lastStatus -Name 'processAlive')

        if ($classification -eq 'crashed' -and $ConfirmCrashedDelaySeconds -gt 0) {
            Start-Sleep -Seconds $ConfirmCrashedDelaySeconds
            $pollCount++
            $confirmedStatus = Invoke-StatusRead -StatusScript $statusScript -ResolvedRunDir $resolvedRunDir
            $confirmedClassification = ([string](Get-JsonProperty -Object $confirmedStatus -Name 'classification')).ToLowerInvariant()
            if ($confirmedClassification -ne 'crashed') {
                $lastStatus = $confirmedStatus
                $classification = $confirmedClassification
            }
        }

        if ($classification -eq 'actionable' -and $actionCommandConfigured) {
            if ($processAlive) {
                $classification = 'action_running'
            } else {
                if ($ConfirmCrashedDelaySeconds -gt 0) {
                    Start-Sleep -Seconds $ConfirmCrashedDelaySeconds
                } else {
                    Start-Sleep -Milliseconds 250
                }
                $pollCount++
                $confirmedStatus = Invoke-StatusRead -StatusScript $statusScript -ResolvedRunDir $resolvedRunDir
                $confirmedClassification = ([string](Get-JsonProperty -Object $confirmedStatus -Name 'classification')).ToLowerInvariant()
                $lastStatus = $confirmedStatus
                $classification = $confirmedClassification
                $processAlive = [bool](Get-JsonProperty -Object $lastStatus -Name 'processAlive')
                if ($classification -eq 'actionable' -and -not $processAlive) {
                    $statusWithWaiter = Add-WaiterMetadata -Status $lastStatus -StartedAtUtc $startedAt -PollCount $pollCount -ExitReason 'action_result_missing' -ConsecutiveStalledPolls $consecutiveStalledPolls
                    Write-StatusAndExit -Status $statusWithWaiter -ExitCode $ExitGeneral
                }
            }
        }

        if ($TerminalClassification -contains $classification) {
            $exitCode = Get-WaiterExitCode -Status $lastStatus -Classification $classification
            $statusWithWaiter = Add-WaiterMetadata -Status $lastStatus -StartedAtUtc $startedAt -PollCount $pollCount -ExitReason $classification -ConsecutiveStalledPolls $consecutiveStalledPolls
            Write-StatusAndExit -Status $statusWithWaiter -ExitCode $exitCode
        }

        $isStalledWakeCandidate = $classification -eq 'stalled'
        if ($isStalledWakeCandidate -and $StalledPollsToExit -gt 0) {
            $consecutiveStalledPolls++
            if ($consecutiveStalledPolls -ge $StalledPollsToExit) {
                $statusWithWaiter = Add-WaiterMetadata -Status $lastStatus -StartedAtUtc $startedAt -PollCount $pollCount -ExitReason 'stalled' -ConsecutiveStalledPolls $consecutiveStalledPolls
                Write-StatusAndExit -Status $statusWithWaiter -ExitCode $ExitStalled
            }
        } else {
            $consecutiveStalledPolls = 0
        }

        $elapsedSeconds = [int](((Get-Date).ToUniversalTime()) - $startedAt).TotalSeconds
        if ($TimeoutSeconds -gt 0 -and $elapsedSeconds -ge $TimeoutSeconds) {
            $statusWithWaiter = Add-WaiterMetadata -Status $lastStatus -StartedAtUtc $startedAt -PollCount $pollCount -ExitReason 'waiter_timeout' -TimedOut -ConsecutiveStalledPolls $consecutiveStalledPolls
            Write-StatusAndExit -Status $statusWithWaiter -ExitCode $ExitWaiterTimeout
        }

        $sleepSeconds = $PollIntervalSeconds
        if ($TimeoutSeconds -gt 0) {
            $remaining = $TimeoutSeconds - $elapsedSeconds
            if ($remaining -le 0) {
                continue
            }
            $sleepSeconds = [Math]::Min($sleepSeconds, $remaining)
        }
        Start-Sleep -Seconds $sleepSeconds
    } catch {
        Write-WaiterError "waiter failed: $($_.Exception.Message)"
        exit $ExitGeneral
    }
}
