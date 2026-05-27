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

    [string]$Name = 'loop',
    [string]$RunDir = '',
    [string]$LockName = '',

    [switch]$WatchUntilTerminal,
    [switch]$Invert,
    [switch]$Quiet,
    [switch]$Force,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function ConvertTo-SafeName {
    param([Parameter(Mandatory = $true)][string]$Value)
    $safe = $Value -replace '[^A-Za-z0-9_.-]', '_'
    if ([string]::IsNullOrWhiteSpace($safe)) {
        return 'loop'
    }
    return $safe
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )
    $directory = Split-Path -Parent $Path
    if ($directory) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 12
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $utf8NoBom)
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
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

function ConvertTo-UtcDateTime {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse(([string]$Value).Trim(), [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
    return $null
}

function Test-ManifestProcessAlive {
    param([AllowNull()][object]$Manifest)
    $manifestPid = Get-JsonProperty -Object $Manifest -Name 'pid'
    if ($null -eq $manifestPid) {
        return $false
    }
    $processId = 0
    if (-not [int]::TryParse(([string]$manifestPid).Trim(), [ref]$processId) -or $processId -le 0) {
        return $false
    }
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if (-not $process) {
        return $false
    }

    $expectedStart = ConvertTo-UtcDateTime -Value (Get-JsonProperty -Object $Manifest -Name 'processStartTime')
    if (-not $expectedStart) {
        return $true
    }
    try {
        $actualStart = $process.StartTime.ToUniversalTime()
        return [Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -le 2
    } catch {
        return $false
    }
}

function ConvertTo-ProcessArgumentString {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    ($Arguments | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_ -replace '"', '\"') + '"'
        } else {
            $_
        }
    }) -join ' '
}

function ConvertTo-PowerShellSingleQuotedString {
    param([Parameter(Mandatory = $true)][string]$Value)
    "'" + ($Value -replace "'", "''") + "'"
}

$safeName = ConvertTo-SafeName -Value $Name
$runDirProvided = -not [string]::IsNullOrWhiteSpace($RunDir)
if (-not $RunDir) {
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $RunDir = Join-Path $HOME (".copilot\loop-runs\{0}-{1}-{2}" -f $safeName, $timestamp, $suffix)
}
$RunDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunDir)
$manifestPath = Join-Path $RunDir 'manifest.json'
if ($runDirProvided -and -not $Force -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    $existingManifest = Read-JsonFile -Path $manifestPath
    if (Test-ManifestProcessAlive -Manifest $existingManifest) {
        throw "Run directory already contains a live loop. Use -Force to overwrite: $RunDir"
    }
}
New-Item -ItemType Directory -Force -Path $RunDir | Out-Null

$scriptDir = $PSScriptRoot
$loopScript = Join-Path $scriptDir 'loop.ps1'
if (-not (Test-Path -LiteralPath $loopScript -PathType Leaf)) {
    throw "Missing loop runner: $loopScript"
}

$paramsPath = Join-Path $RunDir 'params.json'
$pidPath = Join-Path $RunDir 'loop.pid'
$wrapperPath = Join-Path $RunDir 'run-loop.ps1'
$stdoutPath = Join-Path $RunDir 'stdout.log'
$stderrPath = Join-Path $RunDir 'stderr.log'
$lastResultPath = Join-Path $RunDir 'last-result.json'
$heartbeatPath = Join-Path $RunDir 'heartbeat.json'
$eventDir = Join-Path $RunDir 'events'
New-Item -ItemType Directory -Force -Path $eventDir | Out-Null
[System.IO.File]::WriteAllText($stdoutPath, '', [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($stderrPath, '', [System.Text.UTF8Encoding]::new($false))

$timeoutSecondsExplicit = $PSBoundParameters.ContainsKey('TimeoutSeconds')
if ($WatchUntilTerminal -and -not $timeoutSecondsExplicit) {
    $TimeoutSeconds = 0
}
$watchMode = if ($WatchUntilTerminal) { 'watch-until-terminal' } else { 'bounded' }

if (-not $LockName) {
    $LockName = $safeName
}

$params = [ordered]@{
    CheckCommand = $CheckCommand
    ActionCommand = $ActionCommand
    AckCommand = $AckCommand
    OnRetryCommand = $OnRetryCommand
    IntervalSeconds = $IntervalSeconds
    TimeoutSeconds = $TimeoutSeconds
    TimeoutSecondsExplicit = $timeoutSecondsExplicit
    MaxTries = $MaxTries
    BackoffFactor = $BackoffFactor
    MaxIntervalSeconds = $MaxIntervalSeconds
    JitterPercent = $JitterPercent
    StableForSeconds = $StableForSeconds
    RetryExitCode = @($RetryExitCode)
    StopExitCode = @($StopExitCode)
    LockName = $LockName
    LastResultPath = $lastResultPath
    HeartbeatPath = $heartbeatPath
    EventDir = $eventDir
    WatchUntilTerminal = [bool]$WatchUntilTerminal
    WatchMode = $watchMode
    Invert = [bool]$Invert
    Quiet = [bool]$Quiet
    DryRun = $false
}
Write-JsonFile -Path $paramsPath -Value $params

$wrapperLines = @(
    '$ErrorActionPreference = ''Stop''',
    ('& {0} -ParamsFile {1} 1> {2} 2> {3}' -f
        (ConvertTo-PowerShellSingleQuotedString -Value $loopScript),
        (ConvertTo-PowerShellSingleQuotedString -Value $paramsPath),
        (ConvertTo-PowerShellSingleQuotedString -Value $stdoutPath),
        (ConvertTo-PowerShellSingleQuotedString -Value $stderrPath))
)
[System.IO.File]::WriteAllText($wrapperPath, ($wrapperLines -join [Environment]::NewLine) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

$powershell = Get-CurrentPowerShellPath
$arguments = @(
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy', 'Bypass',
    '-File', $wrapperPath
)
$argumentString = ConvertTo-ProcessArgumentString -Arguments $arguments

$plan = [ordered]@{
    schemaVersion = 1
    name = $Name
    runDir = $RunDir
    loopScript = $loopScript
    wrapperPath = $wrapperPath
    paramsPath = $paramsPath
    pidPath = $pidPath
    stdoutPath = $stdoutPath
    stderrPath = $stderrPath
    lastResultPath = $lastResultPath
    heartbeatPath = $heartbeatPath
    eventDir = $eventDir
    watchMode = $watchMode
    watchUntilTerminal = [bool]$WatchUntilTerminal
    timeoutSeconds = $TimeoutSeconds
    timeoutSecondsExplicit = $timeoutSecondsExplicit
    command = $powershell
    arguments = $arguments
    argumentString = $argumentString
}

if ($DryRun) {
    $plan | ConvertTo-Json -Depth 12
    return
}

$startProcessArgs = @{
    FilePath = $powershell
    ArgumentList = $argumentString
    WorkingDirectory = (Get-Location).ProviderPath
    PassThru = $true
}
if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
    $startProcessArgs.WindowStyle = 'Hidden'
}
$process = Start-Process @startProcessArgs
$processStartTime = $null
try {
    $process.Refresh()
    $processStartTime = $process.StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
} catch {
    Write-Warning "started loop process $($process.Id), but could not read its start time: $_"
}

[System.IO.File]::WriteAllText($pidPath, [string]$process.Id + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))

$manifest = [ordered]@{}
foreach ($key in $plan.Keys) {
    $manifest[$key] = $plan[$key]
}
$manifest.pid = $process.Id
$manifest.processStartTime = $processStartTime
$manifest.startedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
Write-JsonFile -Path $manifestPath -Value $manifest

$manifest | ConvertTo-Json -Depth 12
