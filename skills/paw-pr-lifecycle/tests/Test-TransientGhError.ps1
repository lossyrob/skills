#requires -Version 7.0
<#
.SYNOPSIS
Regression tests for Test-LoopTransientGhError.

.DESCRIPTION
Verifies that GitHub CLI HTTP 502, 503, and 504 messages are retried while
non-transient client and authentication failures remain actionable.

Run with PowerShell 7+:
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-TransientGhError.ps1

Exit code 0 if all cases pass, 1 otherwise.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$commonPath = Join-Path (Split-Path -Parent $scriptDir) 'scripts\github-loop-common.ps1'
. $commonPath

$cases = @(
  @{ ErrorText = 'gh api user failed with exit code 1. stderr: gh: HTTP 502'; Expect = $true; Note = 'GitHub CLI HTTP 502' }
  @{ ErrorText = 'gh api user failed with exit code 1. stderr: gh: HTTP 503'; Expect = $true; Note = 'GitHub CLI HTTP 503 regression' }
  @{ ErrorText = 'gh api user failed with exit code 1. stderr: gh: HTTP 504'; Expect = $true; Note = 'GitHub CLI HTTP 504' }
  @{ ErrorText = 'gh: 503 Service Unavailable'; Expect = $true; Note = 'descriptive HTTP 503' }
  @{ ErrorText = 'gh: HTTP 404'; Expect = $false; Note = 'non-transient HTTP 404' }
  @{ ErrorText = 'GitHub authentication user mismatch'; Expect = $false; Note = 'authentication mismatch' }
  @{ ErrorText = ''; Expect = $false; Note = 'empty error' }
)

$pass = 0
$fail = 0
foreach ($case in $cases) {
  $actual = Test-LoopTransientGhError -ErrorText $case.ErrorText
  if ($actual -eq $case.Expect) {
    $pass++
    Write-Host ("PASS  {0}" -f $case.Note) -ForegroundColor Green
  } else {
    $fail++
    Write-Host ("FAIL  expect={0} actual={1}  ::  {2}" -f $case.Expect, $actual, $case.Note) -ForegroundColor Red
  }
}

Write-Host ""
Write-Host ("Summary: {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor (& {
  if ($fail -gt 0) { 'Red' } else { 'Green' }
})

if ($fail -gt 0) { exit 1 }
exit 0
