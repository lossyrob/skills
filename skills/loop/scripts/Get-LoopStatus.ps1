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

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    for ($i = 0; $i -lt 2; $i++) {
        try {
            return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            if ($i -eq 0) {
                Start-Sleep -Milliseconds 100
                continue
            }
            throw
        }
    }
}

function Get-JsonProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
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

function Test-ProcessAlive {
    param([int]$ProcessId)
    if ($ProcessId -le 0) {
        return $false
    }
    return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

$RunDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunDir)
$manifestPath = Join-Path $RunDir 'manifest.json'
$manifest = Read-JsonFile -Path $manifestPath

$loopPid = 0
if ($manifest) {
    $manifestPid = Get-JsonProperty -Object $manifest -Name 'pid'
    if ($null -ne $manifestPid) {
        $loopPid = [int]$manifestPid
    }
}
if ($loopPid -le 0) {
    $pidPath = Join-Path $RunDir 'loop.pid'
    if (Test-Path -LiteralPath $pidPath -PathType Leaf) {
        $pidText = (Get-Content -LiteralPath $pidPath -Raw).Trim()
        if ($pidText) {
            $loopPid = [int]$pidText
        }
    }
}

$lastResultPath = if ($manifest) { [string](Get-JsonProperty -Object $manifest -Name 'lastResultPath') } else { '' }
if (-not $lastResultPath) { $lastResultPath = Join-Path $RunDir 'last-result.json' }
$heartbeatPath = if ($manifest) { [string](Get-JsonProperty -Object $manifest -Name 'heartbeatPath') } else { '' }
if (-not $heartbeatPath) { $heartbeatPath = Join-Path $RunDir 'heartbeat.json' }
$eventDir = if ($manifest) { [string](Get-JsonProperty -Object $manifest -Name 'eventDir') } else { '' }
if (-not $eventDir) { $eventDir = Join-Path $RunDir 'events' }

$lastResult = Read-JsonFile -Path $lastResultPath
$heartbeat = Read-JsonFile -Path $heartbeatPath
$latestEventFile = $null
$latestEvent = $null
if (Test-Path -LiteralPath $eventDir -PathType Container) {
    $latestEventFile = Get-ChildItem -LiteralPath $eventDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if ($latestEventFile) {
        $latestEvent = Read-JsonFile -Path $latestEventFile.FullName
    }
}

if ($IntervalSeconds -le 0) {
    $paramsPath = if ($manifest) { [string](Get-JsonProperty -Object $manifest -Name 'paramsPath') } else { '' }
    if ($paramsPath) {
        $params = Read-JsonFile -Path $paramsPath
        $value = Get-JsonProperty -Object $params -Name 'IntervalSeconds'
        if ($null -ne $value) {
            $IntervalSeconds = [int]$value
        }
    }
}
if ($IntervalSeconds -le 0) {
    $IntervalSeconds = 30
}

$now = (Get-Date).ToUniversalTime()
$heartbeatAgeSeconds = $null
$heartbeatFresh = $false
if ($heartbeat) {
    $heartbeatTimestamp = [datetime](Get-JsonProperty -Object $heartbeat -Name 'timestamp')
    $heartbeatAgeSeconds = [int]($now - $heartbeatTimestamp.ToUniversalTime()).TotalSeconds
    $heartbeatFresh = $heartbeatAgeSeconds -le ((2 * $IntervalSeconds) + $GraceSeconds)
}

$alive = Test-ProcessAlive -ProcessId $loopPid
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
    } elseif ($alive -and -not $heartbeatFresh) {
        $classification = 'stalled'
    } elseif (-not $alive -and $latestEvent) {
        $classification = 'final'
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
    classification = $classification
    intervalSeconds = $IntervalSeconds
    graceSeconds = $GraceSeconds
    heartbeatFresh = $heartbeatFresh
    heartbeatAgeSeconds = $heartbeatAgeSeconds
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
