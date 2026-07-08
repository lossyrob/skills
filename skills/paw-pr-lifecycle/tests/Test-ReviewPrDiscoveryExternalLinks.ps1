#requires -Version 7.0
<#
.SYNOPSIS
Regression tests for external PR link discovery.

.DESCRIPTION
Verifies that review-pr-discovery-check.ps1 wakes reviewer discovery when a
GitHub issue comment links an external Azure DevOps pull request.

Run with PowerShell 7+:
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ReviewPrDiscoveryExternalLinks.ps1

Exit code 0 if all cases pass, 1 otherwise.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$skillDir = Split-Path -Parent $scriptDir
$discoveryScript = Join-Path $skillDir 'scripts\review-pr-discovery-check.ps1'
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("paw-discovery-external-pr-test-{0}" -f [System.Guid]::NewGuid())
$oldPath = $env:PATH
$oldGhCommand = $env:PAW_LOOP_GH_COMMAND

function Write-TestFailure {
  param(
    [Parameter(Mandatory)]
    [string]$Message
  )

  Write-Host "FAIL  $Message" -ForegroundColor Red
  exit 1
}

try {
  [void](New-Item -ItemType Directory -Force -Path $tempDir)
  $mockGh = Join-Path $tempDir 'mock-gh.ps1'
  $mockGhCmd = Join-Path $tempDir 'gh.cmd'

  Set-Content -LiteralPath $mockGhCmd -Encoding ascii -Value @"
@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0mock-gh.ps1" %*
"@

  Set-Content -LiteralPath $mockGh -Encoding utf8 -Value @'
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$GhArgs
)

function Write-Json {
  param([AllowNull()][object]$Value)
  $Value | ConvertTo-Json -Depth 20 -Compress
}

if ($GhArgs.Count -ge 2 -and $GhArgs[0] -eq 'auth' -and $GhArgs[1] -eq 'token') {
  Write-Output 'mock-token'
  exit 0
}

if ($GhArgs.Count -ge 2 -and $GhArgs[0] -eq 'api' -and $GhArgs[1] -eq 'user') {
  Write-Json ([pscustomobject]@{ login = 'test-reviewer' })
  exit 0
}

if ($GhArgs.Count -ge 2 -and $GhArgs[0] -eq 'issue' -and $GhArgs[1] -eq 'view') {
  Write-Json ([pscustomobject]@{
    number = 749
    title = 'External PR tracker'
    state = 'OPEN'
    url = 'https://github.com/example/repo/issues/749'
    closedByPullRequestsReferences = @()
  })
  exit 0
}

if ($GhArgs.Count -ge 2 -and $GhArgs[0] -eq 'pr' -and $GhArgs[1] -eq 'list') {
  Write-Json @()
  exit 0
}

if ($GhArgs.Count -ge 2 -and $GhArgs[0] -eq 'api' -and $GhArgs[1] -eq 'repos/example/repo/issues/749/comments') {
  Write-Json @(
    [pscustomobject]@{
      html_url = 'https://github.com/example/repo/issues/749#issuecomment-1'
      created_at = '2026-06-01T02:16:05Z'
      user = [pscustomobject]@{ login = 'implementer' }
      body = 'AzDO PR: https://dev.azure.com/msdata/Database%20Systems/_git/orcasql-breadth/pullrequest/2129154'
    }
  )
  exit 0
}

Write-Error ("Unexpected gh args: {0}" -f ($GhArgs -join ' '))
exit 1
'@

  $env:PATH = "$tempDir;$oldPath"
  $env:PAW_LOOP_GH_COMMAND = $mockGhCmd
  $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $discoveryScript -Repo 'example/repo' -Issue 749 -GhUser 'test-reviewer'
  $exitCode = $LASTEXITCODE
  if ($exitCode -ne 0) {
    Write-TestFailure "expected exit code 0, got $exitCode. Output: $output"
  }

  $result = $output | ConvertFrom-Json
  if ($result.status -ne 'ACTION') {
    Write-TestFailure "expected ACTION status, got '$($result.status)'"
  }

  if ($result.event -ne 'external_pr_found') {
    Write-TestFailure "expected external_pr_found event, got '$($result.event)'"
  }

  if ($result.provider -ne 'azure-devops') {
    Write-TestFailure "expected azure-devops provider, got '$($result.provider)'"
  }

  if ($result.pullRequest -ne 2129154) {
    Write-TestFailure "expected pullRequest 2129154, got '$($result.pullRequest)'"
  }

  if ($result.project -ne 'Database Systems') {
    Write-TestFailure "expected decoded project name, got '$($result.project)'"
  }

  Write-Host 'PASS  issue comment Azure DevOps PR link wakes discovery' -ForegroundColor Green
  Write-Host ''
  Write-Host 'Summary: 1 passed, 0 failed' -ForegroundColor Green
  exit 0
}
finally {
  $env:PATH = $oldPath
  if ($null -eq $oldGhCommand) {
    Remove-Item Env:PAW_LOOP_GH_COMMAND -ErrorAction SilentlyContinue
  } else {
    $env:PAW_LOOP_GH_COMMAND = $oldGhCommand
  }

  Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
