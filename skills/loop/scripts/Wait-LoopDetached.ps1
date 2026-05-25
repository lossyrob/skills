#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RunDir,

    [ValidateRange(1, [int]::MaxValue)]
    [int]$PollIntervalSeconds = 10,

    [Alias('MaxAttachedSeconds')]
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
$ExitWaiterInternalError = 121
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

function Read-TextFileShared {
    param([Parameter(Mandatory = $true)][string]$Path)
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    try {
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
        try {
            return $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return Read-TextFileShared -Path $Path | ConvertFrom-Json
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

function Get-LatestLoopEventFromDir {
    param([Parameter(Mandatory = $true)][string]$EventDir)
    $empty = [pscustomobject]@{ File = $null; Event = $null; Timestamp = $null; Terminal = $false }
    if (-not (Test-Path -LiteralPath $EventDir -PathType Container)) {
        return $empty
    }
    $candidates = @()
    foreach ($file in Get-ChildItem -LiteralPath $EventDir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        try {
            $event = Read-JsonFile -Path $file.FullName
        } catch {
            continue
        }
        if (-not $event) { continue }
        $resultObj = Get-JsonProperty -Object $event -Name 'result'
        $terminal = [bool](Get-JsonProperty -Object $resultObj -Name 'terminal')
        $tsRaw = Get-JsonProperty -Object $event -Name 'timestamp'
        $ts = $null
        if ($tsRaw) {
            try { $ts = [datetime]::Parse([string]$tsRaw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch { $ts = $null }
        }
        if (-not $ts) { $ts = $file.LastWriteTimeUtc }
        $candidates += [pscustomobject]@{ File = $file; Event = $event; Timestamp = $ts; Terminal = $terminal }
    }
    if ($candidates.Count -eq 0) { return $empty }
    return $candidates |
        Sort-Object @{ Expression = { $_.Timestamp }; Descending = $true }, @{ Expression = { $_.Terminal }; Descending = $true }, @{ Expression = { $_.File.Name }; Descending = $true } |
        Select-Object -First 1
}

function Get-DurableLoopFallback {
    <#
    .SYNOPSIS
    Reconstructs a Get-LoopStatus.ps1-shaped status object by reading the
    detached run directory's durable files directly. Used as a recovery
    path when invoking Get-LoopStatus.ps1 fails for any reason (missing,
    not invokable, transient I/O error, malformed JSON, etc.).

    Mirrors the classification subset that Get-LoopStatus.ps1 derives from
    latestEvent + lastResult: actionable / final / crashed / unknown.
    Heartbeat-driven classifications (running / stalled / starting) are not
    reproduced because they require live process state that this fallback
    is not authoritative about.

    Returns $null when the run directory contains no usable durable state.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedRunDir,
        [Parameter(Mandatory = $true)][ref]$Sources
    )

    $sourcesUsed = @()
    $manifestPath = Join-Path $ResolvedRunDir 'manifest.json'
    $lastResultPath = Join-Path $ResolvedRunDir 'last-result.json'
    $heartbeatPath = Join-Path $ResolvedRunDir 'heartbeat.json'
    $eventDir = Join-Path $ResolvedRunDir 'events'

    $manifest = $null
    try { $manifest = Read-JsonFile -Path $manifestPath } catch { $manifest = $null }

    # Allow manifest to redirect file locations the way Get-LoopStatus does.
    if ($manifest) {
        $manifestLastResult = [string](Get-JsonProperty -Object $manifest -Name 'lastResultPath')
        if (-not [string]::IsNullOrWhiteSpace($manifestLastResult) -and (Test-Path -LiteralPath $manifestLastResult -PathType Leaf)) {
            $lastResultPath = $manifestLastResult
        }
        $manifestHeartbeat = [string](Get-JsonProperty -Object $manifest -Name 'heartbeatPath')
        if (-not [string]::IsNullOrWhiteSpace($manifestHeartbeat) -and (Test-Path -LiteralPath $manifestHeartbeat -PathType Leaf)) {
            $heartbeatPath = $manifestHeartbeat
        }
        $manifestEventDir = [string](Get-JsonProperty -Object $manifest -Name 'eventDir')
        if (-not [string]::IsNullOrWhiteSpace($manifestEventDir) -and (Test-Path -LiteralPath $manifestEventDir -PathType Container)) {
            $eventDir = $manifestEventDir
        }
    }

    $lastResult = $null
    try {
        $lastResult = Read-JsonFile -Path $lastResultPath
        if ($lastResult) { $sourcesUsed += 'lastResult' }
    } catch {
        # Best-effort: surface in waiter metadata, do not block fallback.
    }

    $heartbeat = $null
    try { $heartbeat = Read-JsonFile -Path $heartbeatPath } catch { $heartbeat = $null }

    $latestEvent = $null
    $latestEventFile = $null
    $eventCandidate = Get-LatestLoopEventFromDir -EventDir $eventDir
    if ($eventCandidate -and $eventCandidate.Event) {
        $latestEvent = $eventCandidate.Event
        $latestEventFile = $eventCandidate.File
        $sourcesUsed += 'latestEvent'
    }

    # If nothing durable, give up.
    if (-not $lastResult -and -not $latestEvent -and -not $manifest -and -not $heartbeat) {
        $Sources.Value = @()
        return $null
    }

    # Derive classification from latestEvent.result (preferred) or lastResult.
    $classification = 'unknown'
    $sourceResult = $null
    if ($latestEvent) {
        $sourceResult = Get-JsonProperty -Object $latestEvent -Name 'result'
    }
    if (-not $sourceResult -and $lastResult) {
        $sourceResult = $lastResult
    }
    if ($sourceResult) {
        $loopStatusText = ([string](Get-JsonProperty -Object $sourceResult -Name 'loopStatus')).ToLowerInvariant()
        $terminal = [bool](Get-JsonProperty -Object $sourceResult -Name 'terminal')
        if ($loopStatusText -eq 'actionable') {
            $classification = 'actionable'
        } elseif ($terminal) {
            $classification = 'final'
        }
    }

    $Sources.Value = $sourcesUsed

    return [ordered]@{
        schemaVersion = 1
        timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        runDir = $ResolvedRunDir
        pid = if ($manifest) { Get-JsonProperty -Object $manifest -Name 'pid' } else { $null }
        processAlive = $null
        processExists = $null
        classification = $classification
        recoveredFromDurableFiles = $true
        manifestPath = $manifestPath
        lastResultPath = $lastResultPath
        heartbeatPath = $heartbeatPath
        eventDir = $eventDir
        latestEventPath = if ($latestEventFile) { $latestEventFile.FullName } else { $null }
        manifest = $manifest
        heartbeat = $heartbeat
        lastResult = $lastResult
        latestEvent = $latestEvent
    } | ForEach-Object { [pscustomobject]$_ }
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
                try {
                    $stderrText = Read-TextFileShared -Path $stderrPath
                } catch {
                    $stderrText = ''
                }
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
        # Always emit a JSON status object instead of bare-text failure, so the
        # invoking agent can parse the waiter response uniformly.
        #
        # Recovery strategy (durable-first per the source-of-truth invariant:
        # the detached loop run directory is authoritative, the attached
        # waiter is only a transport/wakeup mechanism):
        #
        #   1. Read durable run-directory files (manifest, last-result, events)
        #      directly via Get-DurableLoopFallback. If they yield an
        #      actionable or final classification, classify and exit through
        #      the normal Get-WaiterExitCode / Write-StatusAndExit path with
        #      waiter.exitReason = 'status_read_fallback'. This is the path
        #      that recovers a missed re-review / approval / +1 etc. that the
        #      worker already finalized but the helper-based status read
        #      could not surface.
        #
        #   2. If the durable read did not yield a usable classification,
        #      fall back to the most recent good in-memory status from a
        #      prior poll, then to a minimal stub. In either case emit JSON
        #      with waiter.exitReason = 'waiter_internal_error' and exit
        #      ExitWaiterInternalError (121).
        #
        # Only emit a bare-text failure if even building the JSON fails.
        $waiterError = $_.Exception.Message
        $waiterErrors = @($waiterError)

        $fallbackSourcesRef = [ref]@()
        $durableStatus = $null
        try {
            $durableStatus = Get-DurableLoopFallback -ResolvedRunDir $resolvedRunDir -Sources $fallbackSourcesRef
        } catch {
            $waiterErrors += "durable fallback read failed: $($_.Exception.Message)"
        }
        $durableSources = @($fallbackSourcesRef.Value)

        if ($durableStatus) {
            $durableClassification = ([string](Get-JsonProperty -Object $durableStatus -Name 'classification')).ToLowerInvariant()
            if ($durableClassification -in @('actionable', 'final')) {
                # Recovered a real lifecycle event from durable state — exit
                # through the normal path so the agent sees the same JSON
                # shape and exit code it would have gotten on a clean read.
                try {
                    $exitCode = Get-WaiterExitCode -Status $durableStatus -Classification $durableClassification
                    $statusWithWaiter = Add-WaiterMetadata -Status $durableStatus -StartedAtUtc $startedAt -PollCount $pollCount -ExitReason 'status_read_fallback' -ConsecutiveStalledPolls $consecutiveStalledPolls
                    $statusWithWaiter | Add-Member -NotePropertyName waiterFallbackSource -NotePropertyValue 'durable_files' -Force
                    $statusWithWaiter | Add-Member -NotePropertyName waiterFallbackDurableSources -NotePropertyValue $durableSources -Force
                    $statusWithWaiter | Add-Member -NotePropertyName waiterErrors -NotePropertyValue $waiterErrors -Force
                    Write-StatusAndExit -Status $statusWithWaiter -ExitCode $exitCode
                } catch {
                    $waiterErrors += "durable fallback exit path failed: $($_.Exception.Message)"
                }
            }
        }

        # Durable read either yielded nothing usable or its exit path
        # itself failed. Build a best-effort status for the internal-error
        # path, preferring the most recent good in-memory status, then the
        # durable status (even if unclassified), then a minimal stub.
        if ($null -ne $lastStatus) {
            $fallbackStatus = $lastStatus
            $fallbackSource = 'previous_status_read'
        } elseif ($null -ne $durableStatus) {
            $fallbackStatus = $durableStatus
            $fallbackSource = 'durable_files_unclassified'
        } else {
            $directLastResult = $null
            try {
                $directLastResult = Read-JsonFile -Path (Join-Path $resolvedRunDir 'last-result.json')
            } catch {
                # Already recorded above when Get-DurableLoopFallback ran.
            }
            $fallbackStatus = [pscustomobject]@{
                runDir = $resolvedRunDir
                classification = $null
                processAlive = $null
                lastResult = $directLastResult
            }
            $fallbackSource = if ($null -ne $directLastResult) { 'last_result_on_disk' } else { 'stub_only' }
        }

        try {
            $statusWithWaiter = Add-WaiterMetadata -Status $fallbackStatus -StartedAtUtc $startedAt -PollCount $pollCount -ExitReason 'waiter_internal_error' -ConsecutiveStalledPolls $consecutiveStalledPolls
        } catch {
            Write-WaiterError "waiter failed: $waiterError"
            Write-WaiterError "waiter recovery also failed: $($_.Exception.Message)"
            exit $ExitWaiterInternalError
        }

        $statusWithWaiter | Add-Member -NotePropertyName waiterError -NotePropertyValue $waiterError -Force
        $statusWithWaiter | Add-Member -NotePropertyName waiterFallbackSource -NotePropertyValue $fallbackSource -Force
        $statusWithWaiter | Add-Member -NotePropertyName waiterErrors -NotePropertyValue $waiterErrors -Force
        if ($durableSources.Count -gt 0) {
            $statusWithWaiter | Add-Member -NotePropertyName waiterFallbackDurableSources -NotePropertyValue $durableSources -Force
        }
        Write-StatusAndExit -Status $statusWithWaiter -ExitCode $ExitWaiterInternalError
    }
}
