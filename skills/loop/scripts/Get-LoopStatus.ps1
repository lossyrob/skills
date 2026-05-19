#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RunDir,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$IntervalSeconds = 0,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$GraceSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Warnings = @()

function Add-StatusWarning {
    param([Parameter(Mandatory = $true)][string]$Message)
    $script:Warnings += $Message
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    for ($i = 0; $i -lt 3; $i++) {
        try {
            return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            if ($i -lt 2) {
                Start-Sleep -Milliseconds 100
                continue
            }
            Add-StatusWarning "Could not read JSON file '$Path': $($_.Exception.Message)"
            return $null
        }
    }
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

function ConvertTo-IntValue {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$Default = 0,
        [switch]$WarnOnInvalid
    )
    if ($null -eq $Value) {
        return $Default
    }
    $text = ([string]$Value).Trim().Trim([char]0xFEFF).Trim()
    if (-not $text) {
        return $Default
    }
    $parsed = 0
    if ([int]::TryParse($text, [ref]$parsed)) {
        return $parsed
    }
    if ($WarnOnInvalid) {
        Add-StatusWarning "Could not parse $Name value '$text' as an integer"
    }
    return $Default
}

function ConvertTo-UtcDateTime {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Value) {
        return $null
    }
    $text = ([string]$Value).Trim()
    if (-not $text) {
        return $null
    }
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
    Add-StatusWarning "Could not parse $Name timestamp '$text'"
    return $null
}

function Resolve-FullPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BaseDir
    )
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BaseDir $Path))
}

function Test-PathUnderDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $comparison = [System.StringComparison]::Ordinal
    if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $comparison = [System.StringComparison]::OrdinalIgnoreCase
    }
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $fullCandidate = [System.IO.Path]::GetFullPath($Candidate)
    return $fullCandidate.Equals($fullRoot, $comparison) -or
        $fullCandidate.StartsWith($fullRoot + [System.IO.Path]::DirectorySeparatorChar, $comparison) -or
        $fullCandidate.StartsWith($fullRoot + [System.IO.Path]::AltDirectorySeparatorChar, $comparison)
}

function Get-RunChildPath {
    param(
        [AllowNull()][object]$Manifest,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][string]$FallbackLeaf
    )
    $fallback = Join-Path $RunDir $FallbackLeaf
    $value = Get-JsonProperty -Object $Manifest -Name $PropertyName
    if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
        return $fallback
    }
    try {
        $candidate = Resolve-FullPath -Path ([string]$value) -BaseDir $RunDir
    } catch {
        Add-StatusWarning "Ignoring invalid manifest path for '$PropertyName': $value"
        return $fallback
    }
    if (-not (Test-PathUnderDirectory -Candidate $candidate -Root $RunDir)) {
        Add-StatusWarning "Ignoring manifest path outside run directory for '$PropertyName': $candidate"
        return $fallback
    }
    return $candidate
}

function Get-ProcessStatus {
    param(
        [int]$ProcessId,
        [AllowNull()][object]$ExpectedStartTimeUtc = $null
    )
    $status = [ordered]@{
        exists = $false
        alive = $false
        startTime = $null
        expectedStartTime = if ($ExpectedStartTimeUtc) { $ExpectedStartTimeUtc.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') } else { $null }
        startTimeMatches = $null
    }
    if ($ProcessId -le 0) {
        return [pscustomobject]$status
    }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) {
        return [pscustomobject]$status
    }

    $status.exists = $true
    $processStart = $null
    try {
        $processStart = $process.StartTime.ToUniversalTime()
        $status.startTime = $processStart.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    } catch {
        Add-StatusWarning "Could not read start time for PID ${ProcessId}: $($_.Exception.Message)"
    }

    if ($ExpectedStartTimeUtc) {
        if ($processStart) {
            $status.startTimeMatches = [Math]::Abs(($processStart - $ExpectedStartTimeUtc).TotalSeconds) -le 2
            $status.alive = [bool]$status.startTimeMatches
        } else {
            $status.startTimeMatches = $false
            $status.alive = $false
        }
    } else {
        $status.alive = $true
    }
    return [pscustomobject]$status
}

function Get-LatestLoopEvent {
    param([Parameter(Mandatory = $true)][string]$EventDir)
    $empty = [pscustomobject]@{
        File = $null
        Event = $null
        Timestamp = $null
        Terminal = $false
    }
    if (-not (Test-Path -LiteralPath $EventDir -PathType Container)) {
        return $empty
    }
    $candidates = @()
    foreach ($file in Get-ChildItem -LiteralPath $EventDir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $event = Read-JsonFile -Path $file.FullName
        if (-not $event) {
            continue
        }
        $eventTimestamp = ConvertTo-UtcDateTime -Value (Get-JsonProperty -Object $event -Name 'timestamp') -Name "event '$($file.Name)'"
        $result = Get-JsonProperty -Object $event -Name 'result'
        $terminal = [bool](Get-JsonProperty -Object $result -Name 'terminal')
        $candidates += [pscustomobject]@{
            File = $file
            Event = $event
            Timestamp = if ($eventTimestamp) { $eventTimestamp } else { $file.LastWriteTimeUtc }
            Terminal = $terminal
        }
    }
    if ($candidates.Count -eq 0) {
        return $empty
    }
    return $candidates |
        Sort-Object @{ Expression = { $_.Timestamp }; Descending = $true }, @{ Expression = { $_.Terminal }; Descending = $true }, @{ Expression = { $_.File.Name }; Descending = $true } |
        Select-Object -First 1
}

$RunDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunDir)
$RunDir = [System.IO.Path]::GetFullPath($RunDir)
$manifestPath = Join-Path $RunDir 'manifest.json'
$manifest = Read-JsonFile -Path $manifestPath

$loopPid = ConvertTo-IntValue -Value (Get-JsonProperty -Object $manifest -Name 'pid') -Name 'manifest pid'
if ($loopPid -le 0) {
    $pidPath = Join-Path $RunDir 'loop.pid'
    if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
        $pidText = Get-Content -LiteralPath $pidPath -Raw -Encoding UTF8
        $loopPid = ConvertTo-IntValue -Value $pidText -Name 'loop.pid' -WarnOnInvalid
    }
}

$lastResultPath = Get-RunChildPath -Manifest $manifest -PropertyName 'lastResultPath' -FallbackLeaf 'last-result.json'
$heartbeatPath = Get-RunChildPath -Manifest $manifest -PropertyName 'heartbeatPath' -FallbackLeaf 'heartbeat.json'
$eventDir = Get-RunChildPath -Manifest $manifest -PropertyName 'eventDir' -FallbackLeaf 'events'
$paramsPath = Get-RunChildPath -Manifest $manifest -PropertyName 'paramsPath' -FallbackLeaf 'params.json'

$lastResult = Read-JsonFile -Path $lastResultPath
$heartbeat = Read-JsonFile -Path $heartbeatPath
$latestEventCandidate = Get-LatestLoopEvent -EventDir $eventDir
$latestEventFile = $latestEventCandidate.File
$latestEvent = $latestEventCandidate.Event

$intervalSource = 'argument'
if ($IntervalSeconds -le 0) {
    $params = Read-JsonFile -Path $paramsPath
    $value = Get-JsonProperty -Object $params -Name 'IntervalSeconds'
    $IntervalSeconds = ConvertTo-IntValue -Value $value -Name 'IntervalSeconds'
    $intervalSource = if ($IntervalSeconds -gt 0) { 'params' } else { 'fallback' }
}
if ($IntervalSeconds -le 0) {
    $IntervalSeconds = 30
    Add-StatusWarning 'IntervalSeconds was not provided and could not be read from params.json; using fallback of 30 seconds'
}

$now = (Get-Date).ToUniversalTime()
$heartbeatTimestamp = ConvertTo-UtcDateTime -Value (Get-JsonProperty -Object $heartbeat -Name 'timestamp') -Name 'heartbeat'
$heartbeatAgeSeconds = $null
$heartbeatFresh = $false
$heartbeatFreshUntil = $null
$heartbeatFreshnessSource = 'none'
if ($heartbeatTimestamp) {
    $heartbeatAgeSeconds = [int]($now - $heartbeatTimestamp).TotalSeconds
    $nextAttemptAfter = ConvertTo-UtcDateTime -Value (Get-JsonProperty -Object $heartbeat -Name 'nextAttemptAfter') -Name 'heartbeat.nextAttemptAfter'
    $nextSleepSeconds = ConvertTo-IntValue -Value (Get-JsonProperty -Object $heartbeat -Name 'nextSleepSeconds') -Name 'heartbeat.nextSleepSeconds'
    if ($nextAttemptAfter) {
        $heartbeatFreshUntil = $nextAttemptAfter.AddSeconds($GraceSeconds)
        $heartbeatFreshnessSource = 'nextAttemptAfter'
    } elseif ($nextSleepSeconds -gt 0) {
        $heartbeatFreshUntil = $heartbeatTimestamp.AddSeconds($nextSleepSeconds + $GraceSeconds)
        $heartbeatFreshnessSource = 'nextSleepSeconds'
    } else {
        $heartbeatFreshUntil = $heartbeatTimestamp.AddSeconds((2 * $IntervalSeconds) + $GraceSeconds)
        $heartbeatFreshnessSource = 'interval'
    }
    $heartbeatFresh = $now -le $heartbeatFreshUntil
}

$expectedProcessStart = ConvertTo-UtcDateTime -Value (Get-JsonProperty -Object $manifest -Name 'processStartTime') -Name 'manifest.processStartTime'
$processStatus = Get-ProcessStatus -ProcessId $loopPid -ExpectedStartTimeUtc $expectedProcessStart
$alive = [bool]$processStatus.alive
$classification = 'unknown'
$terminal = $false

if ($latestEvent) {
    $eventResult = Get-JsonProperty -Object $latestEvent -Name 'result'
    $eventLoopStatus = [string](Get-JsonProperty -Object $eventResult -Name 'loopStatus')
    $terminal = [bool](Get-JsonProperty -Object $eventResult -Name 'terminal')
    if ($eventLoopStatus -eq 'actionable') {
        $classification = 'actionable'
    } elseif ($terminal) {
        $classification = 'final'
    }
}

if ($classification -eq 'unknown') {
    if ($alive -and -not $heartbeat) {
        $classification = 'starting'
    } elseif ($alive -and $heartbeatFresh) {
        $classification = 'running'
    } elseif ($alive) {
        $classification = 'stalled'
    } elseif (-not $alive) {
        $classification = 'crashed'
    }
}

[ordered]@{
    schemaVersion = 1
    timestamp = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    runDir = $RunDir
    pid = $loopPid
    processAlive = $alive
    processExists = [bool]$processStatus.exists
    processStartTime = $processStatus.startTime
    expectedProcessStartTime = $processStatus.expectedStartTime
    processStartTimeMatches = $processStatus.startTimeMatches
    classification = $classification
    intervalSeconds = $IntervalSeconds
    intervalSource = $intervalSource
    graceSeconds = $GraceSeconds
    heartbeatFresh = $heartbeatFresh
    heartbeatAgeSeconds = $heartbeatAgeSeconds
    heartbeatFreshUntil = if ($heartbeatFreshUntil) { $heartbeatFreshUntil.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') } else { $null }
    heartbeatFreshnessSource = $heartbeatFreshnessSource
    warnings = $script:Warnings
    manifestPath = $manifestPath
    lastResultPath = $lastResultPath
    heartbeatPath = $heartbeatPath
    eventDir = $eventDir
    latestEventPath = if ($latestEventFile) { $latestEventFile.FullName } else { $null }
    manifest = $manifest
    heartbeat = $heartbeat
    lastResult = $lastResult
    latestEvent = $latestEvent
} | ConvertTo-Json -Depth 12
