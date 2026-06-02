#Requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RunRoot = (Join-Path $HOME '.copilot\loop-runs'),

    [ValidateRange(0, [int]::MaxValue)]
    [int]$RetentionDays = 7,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$MaxCompletedRuns = 50,

    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) {
        return 0
    }
    $parsed = 0
    if ([int]::TryParse(([string]$Value).Trim(), [ref]$parsed)) {
        return $parsed
    }
    return 0
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
    $processId = ConvertTo-IntValue -Value (Get-JsonProperty -Object $Manifest -Name 'pid')
    if ($processId -le 0) {
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

function Get-LatestLoopEvent {
    param([Parameter(Mandatory = $true)][string]$EventDir)
    if (-not (Test-Path -LiteralPath $EventDir -PathType Container)) {
        return $null
    }
    $candidates = @()
    foreach ($file in Get-ChildItem -LiteralPath $EventDir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        try {
            $eventObject = Read-JsonFile -Path $file.FullName
        } catch {
            continue
        }
        if (-not $eventObject) {
            continue
        }
        $timestamp = ConvertTo-UtcDateTime -Value (Get-JsonProperty -Object $eventObject -Name 'timestamp')
        $candidates += [pscustomobject]@{
            File = $file
            Event = $eventObject
            Timestamp = if ($timestamp) { $timestamp } else { $file.LastWriteTimeUtc }
        }
    }
    if ($candidates.Count -eq 0) {
        return $null
    }
    return $candidates | Sort-Object @{ Expression = { $_.Timestamp }; Descending = $true }, @{ Expression = { $_.File.Name }; Descending = $true } | Select-Object -First 1
}

function Get-RunClassification {
    param(
        [Parameter(Mandatory = $true)][string]$RunDir,
        [AllowNull()][object]$Manifest
    )
    $eventDir = Join-Path $RunDir 'events'
    $latestEvent = Get-LatestLoopEvent -EventDir $eventDir
    $result = $null
    $completedAt = $null
    if ($latestEvent) {
        $result = Get-JsonProperty -Object $latestEvent.Event -Name 'result'
        $completedAt = $latestEvent.Timestamp
    }
    if (-not $result) {
        $lastResultPath = Join-Path $RunDir 'last-result.json'
        try {
            $result = Read-JsonFile -Path $lastResultPath
            if ($result) {
                $completedAt = ConvertTo-UtcDateTime -Value (Get-JsonProperty -Object $result -Name 'timestamp')
            }
        } catch {
            return [pscustomobject]@{ Classification = 'ambiguous'; CompletedAt = $null; Reason = "could not read last-result.json: $($_.Exception.Message)" }
        }
    }
    if (-not $result) {
        return [pscustomobject]@{ Classification = 'ambiguous'; CompletedAt = $null; Reason = 'no terminal event or last result found' }
    }

    $loopStatus = ([string](Get-JsonProperty -Object $result -Name 'loopStatus')).ToLowerInvariant()
    $terminal = [bool](Get-JsonProperty -Object $result -Name 'terminal')
    if (-not $terminal) {
        return [pscustomobject]@{ Classification = 'ambiguous'; CompletedAt = $completedAt; Reason = "latest result is non-terminal ($loopStatus)" }
    }
    if ($loopStatus -in @('success', 'action_completed')) {
        return [pscustomobject]@{ Classification = 'final-success'; CompletedAt = $completedAt; Reason = $loopStatus }
    }
    if ($loopStatus -eq 'actionable') {
        return [pscustomobject]@{ Classification = 'actionable'; CompletedAt = $completedAt; Reason = $loopStatus }
    }
    if ($loopStatus -eq 'abandoned') {
        return [pscustomobject]@{ Classification = 'abandoned'; CompletedAt = $completedAt; Reason = $loopStatus }
    }
    return [pscustomobject]@{ Classification = 'retain'; CompletedAt = $completedAt; Reason = if ($loopStatus) { $loopStatus } else { 'terminal non-success' } }
}

$resolvedRunRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunRoot)
$resolvedRunRoot = [System.IO.Path]::GetFullPath($resolvedRunRoot)
$now = (Get-Date).ToUniversalTime()
$runs = @()

if (Test-Path -LiteralPath $resolvedRunRoot -PathType Container) {
    foreach ($dir in Get-ChildItem -LiteralPath $resolvedRunRoot -Directory -ErrorAction SilentlyContinue) {
        $manifest = $null
        $warnings = @()
        try {
            $manifest = Read-JsonFile -Path (Join-Path $dir.FullName 'manifest.json')
        } catch {
            $warnings += "could not read manifest.json: $($_.Exception.Message)"
        }

        $live = Test-ManifestProcessAlive -Manifest $manifest
        $classification = if ($live) {
            [pscustomobject]@{ Classification = 'live'; CompletedAt = $null; Reason = 'process is alive' }
        } else {
            Get-RunClassification -RunDir $dir.FullName -Manifest $manifest
        }

        if ($classification.Reason) {
            $warnings += $classification.Reason
        }

        $runs += [pscustomobject]@{
            Path = $dir.FullName
            Name = $dir.Name
            Classification = $classification.Classification
            CompletedAt = $classification.CompletedAt
            LastWriteTimeUtc = $dir.LastWriteTimeUtc
            ManifestPid = ConvertTo-IntValue -Value (Get-JsonProperty -Object $manifest -Name 'pid')
            Live = $live
            Eligible = $false
            Action = 'skip'
            Reason = ''
            Warnings = @($warnings)
        }
    }
}

$completedRuns = @($runs | Where-Object { $_.Classification -in @('final-success', 'abandoned') } | Sort-Object @{ Expression = { if ($_.CompletedAt) { $_.CompletedAt } else { $_.LastWriteTimeUtc } }; Descending = $true })
for ($i = 0; $i -lt $completedRuns.Count; $i++) {
    $run = $completedRuns[$i]
    $completedAt = if ($run.CompletedAt) { $run.CompletedAt } else { $run.LastWriteTimeUtc }
    $ageDays = ($now - $completedAt).TotalDays
    if ($i -lt $MaxCompletedRuns) {
        $run.Reason = "retained as one of the newest $MaxCompletedRuns completed runs"
        continue
    }
    if ($ageDays -lt $RetentionDays) {
        $run.Reason = "retained until retention period elapses ($([Math]::Round($ageDays, 2))d < ${RetentionDays}d)"
        continue
    }
    $run.Eligible = $true
    $run.Action = if ($Apply) { 'delete' } else { 'would-delete' }
    $run.Reason = "eligible old $($run.Classification) run"
}

foreach ($run in $runs | Where-Object { $_.Classification -notin @('final-success', 'abandoned') }) {
    switch ($run.Classification) {
        'live' { $run.Reason = 'live run' }
        'actionable' { $run.Reason = 'retained actionable run' }
        'retain' { $run.Reason = 'retained diagnostic terminal run' }
        default { $run.Reason = 'ambiguous or malformed run retained' }
    }
}

$deleted = 0
$deleteFailures = 0
if ($Apply) {
    foreach ($run in $runs | Where-Object { $_.Eligible }) {
        if ($PSCmdlet.ShouldProcess($run.Path, 'Remove loop run directory')) {
            try {
                Remove-Item -LiteralPath $run.Path -Recurse -Force -ErrorAction Stop
                $deleted++
            } catch {
                $deleteFailures++
                $run.Action = 'skip'
                $run.Reason = "delete failed: $($_.Exception.Message)"
                $run.Eligible = $false
            }
        }
    }
}

[ordered]@{
    schemaVersion = 1
    timestamp = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    runRoot = $resolvedRunRoot
    apply = [bool]$Apply
    retentionDays = $RetentionDays
    maxCompletedRuns = $MaxCompletedRuns
    totalRuns = $runs.Count
    eligibleRuns = @($runs | Where-Object { $_.Eligible }).Count
    deletedRuns = $deleted
    deleteFailures = $deleteFailures
    runs = @($runs | Sort-Object Path | ForEach-Object {
        [ordered]@{
            path = $_.Path
            name = $_.Name
            classification = $_.Classification
            completedAt = if ($_.CompletedAt) { $_.CompletedAt.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') } else { $null }
            live = $_.Live
            eligible = $_.Eligible
            action = $_.Action
            reason = $_.Reason
            warnings = @($_.Warnings)
        }
    })
} | ConvertTo-Json -Depth 8
