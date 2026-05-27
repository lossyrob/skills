param(
  [Parameter(Mandatory)]
  [string]$Repo,

  [Parameter(Mandatory)]
  [Alias("Pr")]
  [int]$PullRequest,

  [string]$Since,

  [string]$ApprovalMarker = "PAW Review: +1",

  [string]$AddressedMarker = "PAW Implementer: Review Addressed",

  [string]$RereviewRequestedMarker = "PAW Implementer: Re-review Requested",

  [string]$GhUser
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "github-loop-common.ps1")

function Get-ReviewResponseCachePath {
  param(
    [Parameter(Mandatory)]
    [string]$Repo,

    [Parameter(Mandatory)]
    [int]$PullRequest
  )

  $safeRepo = $Repo -replace "[^A-Za-z0-9_.-]", "_"
  return (Join-Path (Get-LoopCacheDirectory) "impl-review-response-$safeRepo-$PullRequest.json")
}

function Read-ReviewResponseCache {
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return $null
  }

  try {
    return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -NoEnumerate)
  }
  catch {
    return $null
  }
}

function Write-ReviewResponseCache {
  param(
    [Parameter(Mandatory)]
    [string]$Path,

    [Parameter(Mandatory)]
    [System.Collections.IDictionary]$Data
  )

  try {
    $Data | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8
  }
  catch {
    # Cache writes are best-effort; the next attempt can still perform a full check.
  }
}

try {
  Assert-LoopGhUser -GhUser $GhUser
  $sinceAt = ConvertTo-LoopDateTimeOffset $Since
  $pr = Get-LoopPullRequest `
    -Repo $Repo `
    -PullRequest $PullRequest `
    -Fields "number,title,state,author,comments,reviews,url,headRefOid,reviewDecision,updatedAt,commits"

  $state = [string](Get-LoopProperty $pr "state")
  if ($state -eq "MERGED") {
    Complete-LoopCheck -Status "ACTION" -Event "already_merged" -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      url = Get-LoopProperty $pr "url"
    }) -ExitCode 0
  }

  if ($state -eq "CLOSED") {
    Complete-LoopCheck -Status "STOP" -Event "closed_unmerged" -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      url = Get-LoopProperty $pr "url"
    }) -ExitCode $script:LoopStopExitCode
  }

  $comments = ConvertTo-LoopArray (Get-LoopProperty $pr "comments")
  $reviews = ConvertTo-LoopArray (Get-LoopProperty $pr "reviews")
  $reviewComments = @()
  $headRefOid = [string](Get-LoopProperty $pr "headRefOid")
  $prUpdatedAt = [string](Get-LoopProperty $pr "updatedAt")
  $reviewDecision = Get-LoopProperty $pr "reviewDecision"
  $headCommitAt = $null
  foreach ($commit in (ConvertTo-LoopArray (Get-LoopProperty $pr "commits"))) {
    $commitOid = [string](Get-LoopProperty $commit "oid")
    if ($commitOid -ne $headRefOid) {
      continue
    }

    $headCommitAt = ConvertTo-LoopDateTimeOffset (Get-LoopProperty $commit "committedDate")
    if ($null -eq $headCommitAt) {
      $headCommitAt = ConvertTo-LoopDateTimeOffset (Get-LoopProperty $commit "authoredDate")
    }
    break
  }

  $cachePath = Get-ReviewResponseCachePath -Repo $Repo -PullRequest $PullRequest
  $cache = Read-ReviewResponseCache -Path $cachePath
  $cachedHeadRefOid = [string](Get-LoopProperty $cache "headRefOid")
  $cachedUpdatedAt = [string](Get-LoopProperty $cache "updatedAt")
  $cachedReviewDecision = [string](Get-LoopProperty $cache "reviewDecision")
  $cachedReviewCount = Get-LoopProperty $cache "reviewCount"
  $cachedAt = ConvertTo-LoopDateTimeOffset (Get-LoopProperty $cache "cachedAt")
  $cacheFresh = $null -ne $cachedAt -and $cachedAt -gt (Get-Date).ToUniversalTime().AddMinutes(-5)
  if (
    $null -ne $cache -and
    $cacheFresh -and
    $cachedHeadRefOid -eq $headRefOid -and
    $cachedUpdatedAt -eq $prUpdatedAt -and
    $cachedReviewDecision -eq ([string]$reviewDecision) -and
    $cachedReviewCount -eq $reviews.Count
  ) {
    Complete-LoopCheck -Status "WAIT" -Event "no_unaddressed_review_or_approval" -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      prUrl = Get-LoopProperty $pr "url"
      headRefOid = Get-LoopProperty $pr "headRefOid"
      headCommitAt = if ($null -eq $headCommitAt) { $null } else { $headCommitAt.ToString("o") }
      reviewDecision = $reviewDecision
      latestAddressedAt = Get-LoopProperty $cache "latestAddressedAt"
      reviewCount = $reviews.Count
      reviewThreadCommentCount = Get-LoopProperty $cache "reviewThreadCommentCount"
      reviewThreadCommentsUnavailable = Get-LoopProperty $cache "reviewThreadCommentsUnavailable"
      cache = "hit"
    }) -ExitCode $script:LoopRetryExitCode
  }

  $latestAddressedAt = $sinceAt
  foreach ($comment in $comments) {
    $commentBody = Get-LoopProperty $comment "body"
    if (
      -not (Test-LoopBodyContains $commentBody $AddressedMarker) -and
      -not (Test-LoopBodyContains $commentBody $RereviewRequestedMarker)
    ) {
      continue
    }

    $createdAt = ConvertTo-LoopDateTimeOffset (Get-LoopCommentCreatedAt $comment)
    if ($null -ne $createdAt -and ($null -eq $latestAddressedAt -or $createdAt -gt $latestAddressedAt)) {
      $latestAddressedAt = $createdAt
    }
  }

  $events = @()

  foreach ($comment in $comments) {
    $createdAt = ConvertTo-LoopDateTimeOffset (Get-LoopCommentCreatedAt $comment)
    if ($null -eq $createdAt -or ($null -ne $latestAddressedAt -and $createdAt -le $latestAddressedAt)) {
      continue
    }

    if (Test-LoopBodyStartsWithMarker (Get-LoopProperty $comment "body") $ApprovalMarker) {
      if ($null -ne $headCommitAt -and $createdAt -le $headCommitAt) {
        continue
      }

      $events += [pscustomobject]@{
        kind = "approval_marker"
        source = "pr_comment"
        id = Get-LoopProperty $comment "id"
        author = Get-LoopCommentAuthorLogin $comment
        url = Get-LoopCommentUrl $comment
        when = $createdAt
      }
    }
  }

  foreach ($review in $reviews) {
    $submittedAt = ConvertTo-LoopDateTimeOffset (Get-LoopProperty $review "submittedAt")
    if ($null -eq $submittedAt -or ($null -ne $latestAddressedAt -and $submittedAt -le $latestAddressedAt)) {
      continue
    }

    $reviewState = [string](Get-LoopProperty $review "state")
    if ($reviewState -in @("PENDING", "DISMISSED")) {
      continue
    }

    $kind = "pr_review_received"
    $reviewCommit = [string](Get-LoopProperty (Get-LoopProperty $review "commit") "oid")
    if ($reviewState -eq "APPROVED" -or (Test-LoopBodyStartsWithMarker (Get-LoopProperty $review "body") $ApprovalMarker)) {
      if (-not [string]::IsNullOrWhiteSpace($reviewCommit) -and -not [string]::IsNullOrWhiteSpace($headRefOid) -and $reviewCommit -ne $headRefOid) {
        continue
      }

      if ([string]::IsNullOrWhiteSpace($reviewCommit) -and $null -ne $headCommitAt -and $submittedAt -le $headCommitAt) {
        continue
      }

      $kind = "approval_review"
    }

    $events += [pscustomobject]@{
      kind = $kind
      source = "pr_review"
      id = Get-LoopProperty $review "id"
      state = $reviewState
      author = Get-LoopProperty (Get-LoopProperty $review "author") "login"
      commit = $reviewCommit
      when = $submittedAt
    }
  }

  $reviewCommentsUnavailable = $null
  if ($events.Count -eq 0 -and $reviews.Count -gt 0) {
    try {
      $reviewComments = ConvertTo-LoopArray (Get-LoopPullRequestReviewComments -Repo $Repo -PullRequest $PullRequest)
    }
    catch {
      $reviewCommentsUnavailable = $_.Exception.Message
      $reviewComments = @()
    }
  }

  foreach ($reviewComment in $reviewComments) {
    $createdAt = ConvertTo-LoopDateTimeOffset (Get-LoopProperty $reviewComment "created_at")
    if ($null -eq $createdAt -or ($null -ne $latestAddressedAt -and $createdAt -le $latestAddressedAt)) {
      continue
    }

    $kind = "review_thread_comment"
    if (Test-LoopBodyStartsWithMarker (Get-LoopProperty $reviewComment "body") $ApprovalMarker) {
      $reviewCommentCommit = [string](Get-LoopProperty $reviewComment "commit_id")
      if (-not [string]::IsNullOrWhiteSpace($reviewCommentCommit) -and -not [string]::IsNullOrWhiteSpace($headRefOid) -and $reviewCommentCommit -ne $headRefOid) {
        continue
      }

      if ([string]::IsNullOrWhiteSpace($reviewCommentCommit) -and $null -ne $headCommitAt -and $createdAt -le $headCommitAt) {
        continue
      }

      $kind = "approval_marker"
    }

    $events += [pscustomobject]@{
      kind = $kind
      source = "review_thread_comment"
      id = Get-LoopProperty $reviewComment "id"
      reviewId = Get-LoopProperty $reviewComment "pull_request_review_id"
      author = Get-LoopProperty (Get-LoopProperty $reviewComment "user") "login"
      url = Get-LoopProperty $reviewComment "html_url"
      commit = Get-LoopProperty $reviewComment "commit_id"
      when = $createdAt
    }
  }

  $latestEvent = Get-LoopLatest $events
  if ($null -ne $latestEvent) {
    $eventKind = [string](Get-LoopProperty $latestEvent "kind")
    $loopEvent = if ($eventKind -in @("approval_marker", "approval_review")) { "approval_detected" } else { "review_detected" }
    Complete-LoopCheck -Status "ACTION" -Event $loopEvent -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      prUrl = Get-LoopProperty $pr "url"
      headRefOid = Get-LoopProperty $pr "headRefOid"
      headCommitAt = if ($null -eq $headCommitAt) { $null } else { $headCommitAt.ToString("o") }
      reviewDecision = $reviewDecision
      latestAddressedAt = if ($null -eq $latestAddressedAt) { $null } else { $latestAddressedAt.ToString("o") }
      source = Get-LoopProperty $latestEvent "source"
      sourceId = Get-LoopProperty $latestEvent "id"
      sourceState = Get-LoopProperty $latestEvent "state"
      sourceAuthor = Get-LoopProperty $latestEvent "author"
      sourceUrl = Get-LoopProperty $latestEvent "url"
      sourceCommit = Get-LoopProperty $latestEvent "commit"
      detectedAt = (Get-LoopProperty $latestEvent "when").ToString("o")
    }) -ExitCode 0
  }

  Write-ReviewResponseCache -Path $cachePath -Data ([ordered]@{
    repo = $Repo
    pullRequest = $PullRequest
    headRefOid = $headRefOid
    updatedAt = $prUpdatedAt
    reviewDecision = $reviewDecision
    latestAddressedAt = if ($null -eq $latestAddressedAt) { $null } else { $latestAddressedAt.ToString("o") }
    reviewCount = $reviews.Count
    reviewThreadCommentCount = $reviewComments.Count
    reviewThreadCommentsUnavailable = $reviewCommentsUnavailable
    cachedAt = (Get-Date).ToUniversalTime().ToString("o")
  })

  Complete-LoopCheck -Status "WAIT" -Event "no_unaddressed_review_or_approval" -Data ([ordered]@{
    repo = $Repo
    pullRequest = $PullRequest
    prUrl = Get-LoopProperty $pr "url"
    headRefOid = Get-LoopProperty $pr "headRefOid"
    headCommitAt = if ($null -eq $headCommitAt) { $null } else { $headCommitAt.ToString("o") }
    reviewDecision = $reviewDecision
    latestAddressedAt = if ($null -eq $latestAddressedAt) { $null } else { $latestAddressedAt.ToString("o") }
    reviewCount = $reviews.Count
    reviewThreadCommentCount = $reviewComments.Count
    reviewThreadCommentsUnavailable = $reviewCommentsUnavailable
  }) -ExitCode $script:LoopRetryExitCode
}
catch {
  Complete-LoopGitHubError -Data ([ordered]@{
    repo = $Repo
    pullRequest = $PullRequest
    ghUser = $GhUser
  }) -ErrorMessage $_.Exception.Message
}
