#requires -Version 7.0
<#
.SYNOPSIS
Regression tests for Test-LoopBodyStartsWithMarker.

.DESCRIPTION
Verifies that PAW marker detection in github-loop-common.ps1 is tolerant of
encoding glitches in PR body text, while still rejecting non-matching bodies.

The motivating regression: a real PAW Review +1 was misclassified as a generic
review_detected event because the leading U+1F43E paw emoji had been decoded
through a cp437 console code page, rendering it as '≡ƒÉ╛'. The marker parser
only stripped the literal paw glyph and so the ASCII portion 'PAW Review: +1'
never matched.

Run with PowerShell 7+:
    pwsh -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-MarkerParser.ps1

Exit code 0 if all cases pass, 1 otherwise.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
$commonPath = Join-Path (Split-Path -Parent $scriptDir) 'scripts\github-loop-common.ps1'
. $commonPath

$paw    = [System.Char]::ConvertFromUtf32(0x1F43E)
$bytes  = [System.Text.Encoding]::UTF8.GetBytes($paw)
$cp437  = [System.Text.Encoding]::GetEncoding(437).GetString($bytes)
$cp1252 = [System.Text.Encoding]::GetEncoding(1252).GetString($bytes)

$cases = @(
  @{ Body = "$paw PAW Review: +1"                                       ; Marker = "$paw PAW Review: +1"                       ; Expect = $true  ; Note = 'real emoji marker' }
  @{ Body = "$cp437 PAW Review: +1"                                     ; Marker = "$paw PAW Review: +1"                       ; Expect = $true  ; Note = 'cp437 mojibake (the regression case)' }
  @{ Body = "$cp1252 PAW Review: +1"                                    ; Marker = "$paw PAW Review: +1"                       ; Expect = $true  ; Note = 'cp1252 mojibake' }
  @{ Body = "PAW Review: +1"                                            ; Marker = "$paw PAW Review: +1"                       ; Expect = $true  ; Note = 'plain ASCII, no emoji' }
  @{ Body = "$paw PAW Implementer: Review Addressed (PRR_xyz)"          ; Marker = "$paw PAW Implementer: Review Addressed"    ; Expect = $true  ; Note = 'addressed marker with trailing detail' }
  @{ Body = "$cp437 PAW Implementer: Re-review Requested`nReason: ..."  ; Marker = "$paw PAW Implementer: Re-review Requested" ; Expect = $true  ; Note = 'mojibaked re-review followed by body' }
  @{ Body = "$paw  PAW Review: +1"                                      ; Marker = "$paw PAW Review: +1"                       ; Expect = $true  ; Note = 'multiple spaces between emoji and marker' }
  @{ Body = "$cp437$cp437 PAW Review: +1"                               ; Marker = "$paw PAW Review: +1"                       ; Expect = $true  ; Note = '2x mojibake still within the 8-code-unit bound' }
  @{ Body = "Looks good, but PAW Review: +1 only after CI"              ; Marker = "$paw PAW Review: +1"                       ; Expect = $false ; Note = 'marker phrase mid-body, not at start' }
  @{ Body = ""                                                          ; Marker = "$paw PAW Review: +1"                       ; Expect = $false ; Note = 'empty body' }
  @{ Body = "$paw PAW Review: -1"                                       ; Marker = "$paw PAW Review: +1"                       ; Expect = $false ; Note = 'negated review must never match approval marker' }
  @{ Body = "$paw PAW Reviewer: +1"                                     ; Marker = "$paw PAW Review: +1"                       ; Expect = $false ; Note = 'similar-looking but wrong marker text' }
  @{ Body = "$cp437$cp437$cp437 PAW Review: +1"                         ; Marker = "$paw PAW Review: +1"                       ; Expect = $false ; Note = '3x mojibake exceeds the 8-code-unit bound (false-negative is acceptable)' }
  @{ Body = "hello $paw PAW Review: +1"                                 ; Marker = "$paw PAW Review: +1"                       ; Expect = $false ; Note = 'real paw embedded inside body does not count as a leading marker' }
)

$pass = 0
$fail = 0
foreach ($c in $cases) {
  $actual = Test-LoopBodyStartsWithMarker -Body $c.Body -Marker $c.Marker
  if ($actual -eq $c.Expect) {
    $pass++
    Write-Host ("PASS  {0}" -f $c.Note) -ForegroundColor Green
  } else {
    $fail++
    Write-Host ("FAIL  expect={0} actual={1}  ::  {2}" -f $c.Expect, $actual, $c.Note) -ForegroundColor Red
  }
}

Write-Host ""
Write-Host ("Summary: {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor (& { if ($fail -gt 0) { 'Red' } else { 'Green' } })

if ($fail -gt 0) { exit 1 }
exit 0
