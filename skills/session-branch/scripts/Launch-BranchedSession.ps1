<#
.SYNOPSIS
Launches a branched Copilot CLI session in a new Windows Terminal tab inside
the current window via the launch-copilot-terminal helper.

.DESCRIPTION
Wraps the optional Step 4 ("Launch in Terminal") flow of the session-branch
skill so SKILL.md does not have to inline the helper-lookup, flag-detection,
cwd-resolution, and launch logic. On success, prints the minimal
launch-announcement message and exits 0. On any recoverable failure (helper
not found, wt.exe missing, invalid cwd, helper non-zero exit), writes a
warning and exits non-zero so the caller can fall back to the standard
report-success output.

.PARAMETER CurrentSession
Path to the current (source) session directory. Used to read the original
cwd from workspace.yaml when no worktree is supplied.

.PARAMETER NewSessionId
The branched session's ID. The launched tab runs `copilot --resume <id>`.

.PARAMETER NewSessionName
The branched session's display title. Used as the Windows Terminal tab title.

.PARAMETER WorktreeDir
Optional. If supplied and the path exists, the new tab launches in this
directory instead of the original session's cwd.

.PARAMETER Color
Windows Terminal tab color. Defaults to "purple".

.PARAMETER LaunchScriptPath
Optional explicit path to the launch-copilot-terminal helper. When omitted,
this script searches the sibling skill directory, the default plugin install
path, and ~/.copilot recursively.

.PARAMETER DryRun
Print the resolved launch parameters and the helper invocation instead of
launching.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$CurrentSession,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$NewSessionId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$NewSessionName,

    [string]$WorktreeDir,

    [ValidateNotNullOrEmpty()]
    [string]$Color = "purple",

    [string]$LaunchScriptPath,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT") {
    Write-Warning "Launch-BranchedSession requires Windows; falling back to standard report."
    exit 2
}

function Find-LaunchHelper {
    param([string]$Override)

    if ($Override) {
        if (Test-Path -LiteralPath $Override -PathType Leaf) {
            return (Resolve-Path -LiteralPath $Override).ProviderPath
        }
        Write-Warning "Provided -LaunchScriptPath '$Override' was not found; trying standard locations."
    }

    $candidates = @()

    # Sibling skill directory (when this script lives in a checked-out skills repo).
    $skillRoot = Split-Path -Parent $PSScriptRoot
    if ($skillRoot) {
        $skillsDir = Split-Path -Parent $skillRoot
        if ($skillsDir) {
            $candidates += (Join-Path $skillsDir "launch-copilot-terminal\Launch-CopilotTerminal.ps1")
        }
    }

    # Default plugin install path.
    $candidates += (Join-Path $HOME ".copilot\skills\launch-copilot-terminal\Launch-CopilotTerminal.ps1")

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $candidate).ProviderPath
        }
    }

    # Fallback: recursive search under ~/.copilot.
    $copilotRoot = Join-Path $HOME ".copilot"
    if (Test-Path -LiteralPath $copilotRoot -PathType Container) {
        $found = Get-ChildItem -Path $copilotRoot -Recurse -Filter "Launch-CopilotTerminal.ps1" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            return $found.FullName
        }
    }

    return $null
}

function Get-CopilotFlagsArray {
    $flagsString = ""
    try {
        $currentProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction SilentlyContinue
        if ($currentProcess -and $currentProcess.ParentProcessId) {
            $parentProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($currentProcess.ParentProcessId)" -ErrorAction SilentlyContinue
            $parentCommand = if ($parentProcess) { $parentProcess.CommandLine } else { "" }
            $flags = [regex]::Matches($parentCommand, '(--yolo|--allow-all|--alt-screen|--model\s+\S+)') | ForEach-Object { $_.Value }
            if ($flags) { $flagsString = ($flags -join ' ') }
        }
    } catch {
        $flagsString = ""
    }

    if ([string]::IsNullOrWhiteSpace($flagsString)) {
        return @()
    }
    return $flagsString.Trim() -split '\s+'
}

function Resolve-LaunchCwd {
    param(
        [string]$WorktreeDir,
        [string]$CurrentSession
    )

    if ($WorktreeDir -and (Test-Path -LiteralPath $WorktreeDir -PathType Container)) {
        return (Resolve-Path -LiteralPath $WorktreeDir).ProviderPath
    }

    if ($CurrentSession -and (Test-Path -LiteralPath $CurrentSession -PathType Container)) {
        $workspacePath = Join-Path $CurrentSession "workspace.yaml"
        if (Test-Path -LiteralPath $workspacePath -PathType Leaf) {
            foreach ($line in Get-Content -LiteralPath $workspacePath -Encoding UTF8) {
                if ($line -match '^cwd:\s*(.*)$') {
                    $value = $Matches[1].Trim().Trim('"').Trim("'")
                    if ($value -and (Test-Path -LiteralPath $value -PathType Container)) {
                        return (Resolve-Path -LiteralPath $value).ProviderPath
                    }
                }
            }
        }
    }

    return (Get-Location).ProviderPath
}

$resolvedHelper = Find-LaunchHelper -Override $LaunchScriptPath
if (-not $resolvedHelper) {
    Write-Warning "Could not locate Launch-CopilotTerminal.ps1; falling back to standard report."
    exit 3
}

$copilotFlags = Get-CopilotFlagsArray
$launchCwd    = Resolve-LaunchCwd -WorktreeDir $WorktreeDir -CurrentSession $CurrentSession

if ($DryRun) {
    [pscustomobject]@{
        helper       = $resolvedHelper
        title        = $NewSessionName
        color        = $Color
        cwd          = $launchCwd
        resume       = $NewSessionId
        window       = "current"
        copilotArgs  = $copilotFlags
    } | ConvertTo-Json -Depth 4
    return
}

try {
    & $resolvedHelper `
        -Title $NewSessionName `
        -Color $Color `
        -Cwd $launchCwd `
        -Resume $NewSessionId `
        -Window current `
        -CopilotArgs $copilotFlags
} catch {
    Write-Warning "Launch helper failed: $($_.Exception.Message). Falling back to standard report."
    exit 4
}

Write-Host ""
Write-Host "OK Branched session: $NewSessionId"
Write-Host "-> Launching it in a new Windows Terminal tab in this window..."
exit 0
