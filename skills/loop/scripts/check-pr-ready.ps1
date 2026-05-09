#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [int]$Pr,

    [string]$Repo = '',

    [switch]$RequireReview
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-PrError {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Invoke-Gh {
    param([string[]]$Arguments)
    & gh @Arguments
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) {
        if ($?) { return 0 }
        return 1
    }
    return [int]$exitCode
}

function Get-GhOutput {
    param([string[]]$Arguments)
    $output = & gh @Arguments 2>$null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "gh exited $exitCode"
    }
    return ($output | Out-String).Trim()
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-PrError 'gh is required to check PR readiness'
    exit 23
}

$repoArgs = @()
if ($Repo) {
    $repoArgs = @('--repo', $Repo)
}

try {
    $query = '[.state, (.isDraft | tostring), (.reviewDecision // "null"), (.mergeStateStatus // "UNKNOWN"), (.mergeable // "UNKNOWN"), (.headRefOid // ""), (.url // "")] | @tsv'
    $args = @('pr', 'view', [string]$Pr) + $repoArgs + @(
        '--json', 'state,isDraft,reviewDecision,mergeStateStatus,mergeable,headRefOid,url',
        '--jq', $query
    )
    $data = Get-GhOutput -Arguments $args
} catch {
    Write-PrError "failed to read PR #$Pr; check gh auth status and repository access"
    exit 23
}

$parts = $data -split "`t", 7
if ($parts.Count -lt 7) {
    Write-PrError "unexpected gh output: $data"
    exit 23
}

$state = $parts[0]
$isDraft = $parts[1]
$review = $parts[2]
$mergeState = $parts[3]
$mergeable = $parts[4]
$headSha = $parts[5]
$url = $parts[6]

Write-Host "pr=$Pr state=$state draft=$isDraft review=$review mergeStateStatus=$mergeState mergeable=$mergeable head=$headSha url=$url"

switch ($state) {
    'MERGED' {
        Write-Host 'PR is already merged'
        exit 0
    }
    'CLOSED' {
        Write-PrError 'PR is closed without being merged'
        exit 22
    }
}

if ($isDraft -eq 'true' -or $mergeState -eq 'DRAFT') {
    Write-Host 'PR is a draft; waiting'
    exit 10
}

if ($mergeable -eq 'UNKNOWN' -or $mergeState -eq 'UNKNOWN') {
    Write-Host 'GitHub is still computing mergeability; waiting'
    exit 10
}

if ($mergeable -eq 'CONFLICTING' -or $mergeState -eq 'DIRTY') {
    Write-PrError 'Merge conflicts detected'
    exit 21
}

if ($mergeState -eq 'BEHIND') {
    Write-PrError 'Branch is behind the base branch'
    exit 11
}

if ($review -eq 'CHANGES_REQUESTED') {
    Write-PrError 'Review changes requested'
    exit 24
}

if ($mergeState -eq 'UNSTABLE') {
    Write-PrError 'Status checks are failing'
    $checkArgs = @('pr', 'checks', [string]$Pr) + $repoArgs + @(
        '--required', '--json', 'name,bucket,link',
        '--jq', '.[] | select(.bucket == "fail") | "failed_check=\(.name) link=\(.link)"'
    )
    & gh @checkArgs 2>$null
    exit 20
}

if ($mergeState -eq 'BLOCKED') {
    $checksExit = Invoke-Gh -Arguments (@('pr', 'checks', [string]$Pr) + $repoArgs + @('--required'))
    if ($checksExit -eq 1) {
        Write-PrError 'Required status checks are failing'
        $checkArgs = @('pr', 'checks', [string]$Pr) + $repoArgs + @(
            '--required', '--json', 'name,bucket,link',
            '--jq', '.[] | select(.bucket == "fail") | "failed_check=\(.name) link=\(.link)"'
        )
        & gh @checkArgs 2>$null
        exit 20
    }
    if ($checksExit -eq 8) {
        Write-Host 'Required status checks are still pending'
        exit 10
    }

    if ($review -eq 'REVIEW_REQUIRED' -or ($RequireReview -and $review -ne 'APPROVED')) {
        Write-Host 'Review approval is still required'
        exit 10
    }

    Write-Host 'PR is blocked by branch protection or merge queue; waiting'
    exit 10
}

if ($mergeState -eq 'CLEAN' -or $mergeState -eq 'HAS_HOOKS') {
    if ($review -eq 'APPROVED' -or ((-not $RequireReview) -and $review -eq 'null')) {
        Write-Host 'PR is ready to merge'
        Write-Host "match_head_commit=$headSha"
        exit 0
    }

    Write-Host 'PR is mergeable, but approval is still required'
    exit 10
}

Write-Host "Unhandled merge state: $mergeState; waiting"
exit 10
