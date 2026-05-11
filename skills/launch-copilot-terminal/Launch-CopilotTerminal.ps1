[CmdletBinding(DefaultParameterSetName = "Prompt")]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Title,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Color,

    [Parameter(Mandatory = $true, ParameterSetName = "Prompt")]
    [ValidateNotNullOrEmpty()]
    [string]$Prompt,

    [Parameter(Mandatory = $true, ParameterSetName = "PromptFile")]
    [ValidateNotNullOrEmpty()]
    [string]$PromptFile,

    [string]$Cwd = (Get-Location).ProviderPath,

    [string[]]$CopilotArgs = @(),

    [ValidateNotNullOrEmpty()]
    [string]$CopilotCommand = "copilot",

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$ColorMap = @{
    "black" = "#000000"
    "white" = "#FFFFFF"
    "red" = "#FF0000"
    "green" = "#00FF00"
    "blue" = "#0000FF"
    "yellow" = "#FFFF00"
    "orange" = "#FFA500"
    "purple" = "#800080"
    "violet" = "#EE82EE"
    "pink" = "#FFC0CB"
    "magenta" = "#FF00FF"
    "fuchsia" = "#FF00FF"
    "cyan" = "#00FFFF"
    "aqua" = "#00FFFF"
    "teal" = "#008080"
    "gray" = "#808080"
    "grey" = "#808080"
    "silver" = "#C0C0C0"
    "maroon" = "#800000"
    "olive" = "#808000"
    "navy" = "#000080"
    "lime" = "#00FF00"
    "brown" = "#A52A2A"
    "gold" = "#FFD700"
    "amber" = "#FFBF00"
    "indigo" = "#4B0082"
    "crimson" = "#DC143C"
    "slate" = "#708090"
    "dark-green" = "#008000"
    "light-green" = "#90EE90"
    "dark-blue" = "#00008B"
    "light-blue" = "#ADD8E6"
    "dark-red" = "#8B0000"
    "bright-red" = "#FF0000"
    "bright-green" = "#00FF00"
    "bright-blue" = "#0000FF"
}

function ConvertTo-PowerShellLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    return "'" + ($Value -replace "'", "''") + "'"
}

function ConvertTo-TabColor {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $trimmed = $Value.Trim()
    $key = $trimmed.ToLowerInvariant()
    if ($ColorMap.ContainsKey($key)) {
        return $ColorMap[$key]
    }

    if ($trimmed -match "^[0-9a-fA-F]{6}$") {
        return "#$trimmed".ToUpperInvariant()
    }

    if ($trimmed -match "^#[0-9a-fA-F]{6}$") {
        return $trimmed.ToUpperInvariant()
    }

    $knownColors = ($ColorMap.Keys | Sort-Object) -join ", "
    throw "Unsupported color '$Value'. Use #RRGGBB/RRGGBB or one of: $knownColors."
}

function Escape-WindowsTerminalArgument {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    return $Value -replace ";", "\;"
}

function Resolve-LaunchDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $providerPath = $resolved.ProviderPath
    if (-not (Test-Path -LiteralPath $providerPath -PathType Container)) {
        throw "Working directory '$Path' is not a directory."
    }

    return $providerPath
}

function Get-PromptText {
    if ($PSCmdlet.ParameterSetName -eq "PromptFile") {
        $resolvedPromptFile = Resolve-Path -LiteralPath $PromptFile -ErrorAction Stop
        return Get-Content -LiteralPath $resolvedPromptFile.ProviderPath -Raw -Encoding UTF8
    }

    return $Prompt
}

function Select-PowerShellExecutable {
    if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
        return "pwsh.exe"
    }

    return "powershell.exe"
}

function New-CopilotLaunchScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [string]$PromptText,

        [Parameter(Mandatory = $true)]
        [string]$Command,

        [string[]]$Args
    )

    $launchRoot = Join-Path $HOME ".copilot\terminal-launches"
    New-Item -ItemType Directory -Force -Path $launchRoot | Out-Null

    $launchScriptPath = Join-Path $launchRoot ("launch-{0}-{1}.ps1" -f ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()), ([guid]::NewGuid().ToString()))
    $promptJson = ConvertTo-Json -InputObject $PromptText -Compress
    $argLiterals = @($Args | ForEach-Object { ConvertTo-PowerShellLiteral $_ })
    $argArray = if ($argLiterals.Count -gt 0) { $argLiterals -join ", " } else { "" }

    $lines = @(
        '$launchScriptPath = $PSCommandPath',
        'if ($launchScriptPath) { Remove-Item -LiteralPath $launchScriptPath -Force -ErrorAction Continue }',
        '$ErrorActionPreference = "Stop"',
        "Set-Location -LiteralPath $(ConvertTo-PowerShellLiteral $Directory)",
        "`$copilotPrompt = ConvertFrom-Json $(ConvertTo-PowerShellLiteral $promptJson)",
        "`$copilotArgs = @($argArray)",
        "& $(ConvertTo-PowerShellLiteral $Command) @copilotArgs '-i' `$copilotPrompt"
    )

    Set-Content -LiteralPath $launchScriptPath -Value ($lines -join [Environment]::NewLine) -Encoding UTF8
    return $launchScriptPath
}

if ($env:OS -ne "Windows_NT") {
    throw "launch-copilot-terminal requires Windows Terminal on Windows."
}

if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
    throw "Windows Terminal command 'wt.exe' was not found in PATH."
}

$resolvedCwd = Resolve-LaunchDirectory -Path $Cwd
$tabColor = ConvertTo-TabColor -Value $Color
$promptText = Get-PromptText
if ([string]::IsNullOrWhiteSpace($promptText)) {
    throw "Prompt must not be empty."
}

$shell = Select-PowerShellExecutable
$launchScript = New-CopilotLaunchScript -Directory $resolvedCwd -PromptText $promptText -Command $CopilotCommand -Args $CopilotArgs

$wtArgs = @(
    "-w",
    "-1",
    "new-tab",
    "--title",
    (Escape-WindowsTerminalArgument -Value $Title),
    "--suppressApplicationTitle",
    "--tabColor",
    $tabColor,
    "-d",
    (Escape-WindowsTerminalArgument -Value $resolvedCwd),
    $shell,
    "-NoExit",
    "-File",
    $launchScript
)

if ($DryRun) {
    [pscustomobject]@{
        command = "wt.exe"
        arguments = $wtArgs
        launchScript = $launchScript
        cwd = $resolvedCwd
        title = $Title
        tabColor = $tabColor
        copilotCommand = $CopilotCommand
        copilotArgs = $CopilotArgs
    } | ConvertTo-Json -Depth 4
    return
}

& wt.exe @wtArgs
if ($LASTEXITCODE -ne 0) {
    throw "wt.exe failed with exit code $LASTEXITCODE."
}

Write-Host "Launched Copilot terminal '$Title' with tab color $tabColor in $resolvedCwd."
