param(
  [Parameter(Mandatory)]
  [string]$Repo,

  [Parameter(Mandatory)]
  [int]$Issue,

  [string]$BaseBranch,

  [string]$GhUser
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "github-loop-common.ps1")

$baseBranchFilter = if ([string]::IsNullOrWhiteSpace($BaseBranch)) { $null } else { $BaseBranch }

function New-PrCandidate {
  param(
    [object]$Pr,
    [string]$Source
  )

  $title = [string](Get-LoopProperty $Pr "title")
  $body = [string](Get-LoopProperty $Pr "body")
  $issuePattern = "(?<![0-9])#$Issue(?![0-9])"
  $closingPattern = "(?i)\b(close[sd]?|fix(e[sd])?|resolve[sd]?)\b.{0,80}$issuePattern"
  $hasTitleReference = $title -match $issuePattern
  $hasBodyReference = $body -match $issuePattern
  $hasClosingReference = "$title`n$body" -match $closingPattern
  $score = 0
  if ($hasTitleReference) {
    $score += 20
  }
  if ($hasBodyReference) {
    $score += 10
  }
  if ($hasClosingReference) {
    $score += 40
  }
  if ([string](Get-LoopProperty $Pr "state") -eq "OPEN") {
    $score += 5
  }

  return [pscustomobject]@{
    number = [int](Get-LoopProperty $Pr "number")
    title = $title
    state = [string](Get-LoopProperty $Pr "state")
    baseRefName = [string](Get-LoopProperty $Pr "baseRefName")
    url = [string](Get-LoopProperty $Pr "url")
    updatedAt = ConvertTo-LoopDateTimeOffset (Get-LoopProperty $Pr "updatedAt")
    source = $Source
    score = $score
    hasClosingReference = $hasClosingReference
    hasTitleReference = $hasTitleReference
    hasBodyReference = $hasBodyReference
    isStrongFallback = ($hasClosingReference -or $hasTitleReference)
  }
}

try {
  Assert-LoopGhUser -GhUser $GhUser
  $issueView = $null
  $issueLookupError = $null
  try {
    $issueView = Invoke-GhJson -Arguments @(
      "issue",
      "view",
      [string]$Issue,
      "--repo",
      $Repo,
      "--json",
      "number,title,state,url,closedByPullRequestsReferences"
    )
  }
  catch {
    $issueLookupError = $_.Exception.Message
    if ($issueLookupError -notmatch "Could not resolve to an issue or pull request") {
      throw
    }
  }

  $candidates = @()
  if ($null -ne $issueView) {
    foreach ($ref in (ConvertTo-LoopArray (Get-LoopProperty $issueView "closedByPullRequestsReferences"))) {
      $refNumber = Get-LoopProperty $ref "number"
      if ($null -eq $refNumber) {
        continue
      }

      $refPr = Get-LoopPullRequest `
        -Repo $Repo `
        -PullRequest ([int]$refNumber) `
        -Fields "number,title,body,state,baseRefName,url,updatedAt"

      if ($null -eq $baseBranchFilter -or [string](Get-LoopProperty $refPr "baseRefName") -eq $baseBranchFilter) {
        $candidates += New-PrCandidate -Pr $refPr -Source "closedByPullRequestsReferences"
      }
    }
  }

  if ($candidates.Count -eq 1) {
    $selected = $candidates | Select-Object -First 1

    Complete-LoopCheck -Status "ACTION" -Event "pr_found" -Data ([ordered]@{
      repo = $Repo
      issue = $Issue
      issueUrl = Get-LoopProperty $issueView "url"
      issueLookupError = $issueLookupError
      baseBranch = $baseBranchFilter
      pullRequest = $selected.number
      prState = $selected.state
      prUrl = $selected.url
      selectionSource = $selected.source
      candidateCount = $candidates.Count
      candidates = @($candidates | Select-Object number, state, baseRefName, source, score, hasClosingReference, hasTitleReference, hasBodyReference, url, title)
    }) -ExitCode 0
  }

  if ($candidates.Count -gt 1) {
    Complete-LoopCheck -Status "STOP" -Event "multiple_closing_pr_references" -Data ([ordered]@{
      repo = $Repo
      issue = $Issue
      issueUrl = Get-LoopProperty $issueView "url"
      issueLookupError = $issueLookupError
      baseBranch = $baseBranchFilter
      candidateCount = $candidates.Count
      candidates = @($candidates | Select-Object number, state, baseRefName, source, score, hasClosingReference, hasTitleReference, hasBodyReference, url, title)
    }) -ExitCode $script:LoopStopExitCode
  }

  $fallbackCandidates = @()
  if ($candidates.Count -eq 0) {
    $searched = Invoke-GhJson -Arguments @(
      "pr",
      "list",
      "--repo",
      $Repo,
      "--state",
      "open",
      "--search",
      "#$Issue",
      "--limit",
      "30",
      "--json",
      "number,title,body,state,baseRefName,url,updatedAt"
    )

    $issuePattern = "(?<![0-9])#$Issue(?![0-9])"
    foreach ($pr in (ConvertTo-LoopArray $searched)) {
      if ($null -ne $baseBranchFilter -and [string](Get-LoopProperty $pr "baseRefName") -ne $baseBranchFilter) {
        continue
      }

      $title = [string](Get-LoopProperty $pr "title")
      $body = [string](Get-LoopProperty $pr "body")
      if ("$title`n$body" -notmatch $issuePattern) {
        continue
      }

      $fallbackCandidates += New-PrCandidate -Pr $pr -Source "pr_search"
    }
  }

  $strongFallbackCandidates = @($fallbackCandidates | Where-Object { $_.isStrongFallback })
  if ($strongFallbackCandidates.Count -eq 1) {
    $selected = $strongFallbackCandidates |
      Sort-Object `
        @{ Expression = "score"; Descending = $true },
        @{ Expression = { if ($_.state -eq "OPEN") { 1 } else { 0 } }; Descending = $true },
        @{ Expression = "updatedAt"; Descending = $true } |
      Select-Object -First 1

    Complete-LoopCheck -Status "ACTION" -Event "pr_found" -Data ([ordered]@{
      repo = $Repo
      issue = $Issue
      issueUrl = Get-LoopProperty $issueView "url"
      issueLookupError = $issueLookupError
      baseBranch = $baseBranchFilter
      pullRequest = $selected.number
      prState = $selected.state
      prUrl = $selected.url
      selectionSource = $selected.source
      candidateCount = $strongFallbackCandidates.Count
      candidates = @($strongFallbackCandidates | Select-Object number, state, baseRefName, source, score, hasClosingReference, hasTitleReference, hasBodyReference, url, title)
    }) -ExitCode 0
  }

  if ($strongFallbackCandidates.Count -gt 1) {
    Complete-LoopCheck -Status "STOP" -Event "multiple_pr_candidates" -Data ([ordered]@{
      repo = $Repo
      issue = $Issue
      issueUrl = Get-LoopProperty $issueView "url"
      issueLookupError = $issueLookupError
      baseBranch = $baseBranchFilter
      candidateCount = $strongFallbackCandidates.Count
      candidates = @($strongFallbackCandidates | Sort-Object @{ Expression = "score"; Descending = $true }, @{ Expression = "updatedAt"; Descending = $true } | Select-Object number, state, baseRefName, source, score, hasClosingReference, hasTitleReference, hasBodyReference, url, title)
    }) -ExitCode $script:LoopStopExitCode
  }

  if ($fallbackCandidates.Count -gt 0) {
    Complete-LoopCheck -Status "WAIT" -Event "weak_pr_references_only" -Data ([ordered]@{
      repo = $Repo
      issue = $Issue
      issueUrl = Get-LoopProperty $issueView "url"
      issueState = Get-LoopProperty $issueView "state"
      issueLookupError = $issueLookupError
      baseBranch = $baseBranchFilter
      candidateCount = $fallbackCandidates.Count
      candidates = @($fallbackCandidates | Sort-Object @{ Expression = "score"; Descending = $true }, @{ Expression = "updatedAt"; Descending = $true } | Select-Object number, state, baseRefName, source, score, hasClosingReference, hasTitleReference, hasBodyReference, url, title)
    }) -ExitCode $script:LoopRetryExitCode
  }

  Complete-LoopCheck -Status "WAIT" -Event "no_pr_found" -Data ([ordered]@{
    repo = $Repo
    issue = $Issue
    issueUrl = Get-LoopProperty $issueView "url"
    issueState = Get-LoopProperty $issueView "state"
    issueLookupError = $issueLookupError
    baseBranch = $baseBranchFilter
  }) -ExitCode $script:LoopRetryExitCode
}
catch {
  Complete-LoopCheck -Status "STOP" -Event "script_or_github_api_error" -Data ([ordered]@{
    repo = $Repo
    issue = $Issue
    ghUser = $GhUser
    error = $_.Exception.Message
  }) -ExitCode $script:LoopStopExitCode
}
