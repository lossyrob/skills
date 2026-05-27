param(
  [Parameter(Mandatory)]
  [string]$Repo,

  [Parameter(Mandatory)]
  [Alias("Pr")]
  [int]$PullRequest,

  [string]$Since,

  [string]$ReviewedHeadRefOid,

  [string]$AddressedMarker = "PAW Implementer: Review Addressed",

  [string]$RereviewRequestMarker = "PAW Implementer: Re-review Requested",

  [ValidateRange(0, [int]::MaxValue)]
  [int]$HeadChangeGraceSeconds = 120,

  [string]$GhUser
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "github-loop-common.ps1")

function Get-LoopAddressedReviewIds {
  param(
    [AllowNull()]
    [object]$Body
  )

  $bodyText = [string]$Body
  $reviewIdMatches = [regex]::Matches($bodyText, "PRR_[A-Za-z0-9_=-]+")
  @($reviewIdMatches | ForEach-Object { [string]$_.Value } | Select-Object -Unique)
}

try {
  Assert-LoopGhUser -GhUser $GhUser
  $sinceAt = ConvertTo-LoopDateTimeOffset $Since
  $pr = Get-LoopPullRequest `
    -Repo $Repo `
    -PullRequest $PullRequest `
    -Fields "number,title,state,comments,reviews,url,headRefOid,reviewDecision,updatedAt"

  $state = [string](Get-LoopProperty $pr "state")
  if ($state -eq "MERGED") {
    Complete-LoopCheck -Status "ACTION" -Event "already_merged" -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      prUrl = Get-LoopProperty $pr "url"
    }) -ExitCode 0
  }

  if ($state -eq "CLOSED") {
    Complete-LoopCheck -Status "STOP" -Event "closed_unmerged" -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      prUrl = Get-LoopProperty $pr "url"
    }) -ExitCode $script:LoopStopExitCode
  }

  $reviews = ConvertTo-LoopArray (Get-LoopProperty $pr "reviews")
  $reviewEvents = @()
  foreach ($review in $reviews) {
    $reviewState = [string](Get-LoopProperty $review "state")
    if ($reviewState -in @("PENDING", "DISMISSED")) {
      continue
    }

    $submittedAt = ConvertTo-LoopDateTimeOffset (Get-LoopProperty $review "submittedAt")
    if ($null -eq $submittedAt) {
      continue
    }

    $reviewEvents += [pscustomobject]@{
      id = Get-LoopProperty $review "id"
      state = $reviewState
      author = Get-LoopProperty (Get-LoopProperty $review "author") "login"
      commit = Get-LoopProperty (Get-LoopProperty $review "commit") "oid"
      when = $submittedAt
    }
  }

  $latestReview = Get-LoopLatest $reviewEvents
  $anchor = $sinceAt
  if ($null -ne $latestReview) {
    $latestReviewAt = Get-LoopProperty $latestReview "when"
    if ($null -eq $anchor -or $latestReviewAt -gt $anchor) {
      $anchor = $latestReviewAt
    }
  }

  $comments = ConvertTo-LoopArray (Get-LoopProperty $pr "comments")
  $addressedEvents = @()
  foreach ($comment in $comments) {
    $commentBody = Get-LoopProperty $comment "body"
    if (-not (Test-LoopBodyContains $commentBody $AddressedMarker)) {
      continue
    }

    $createdAt = ConvertTo-LoopDateTimeOffset (Get-LoopCommentCreatedAt $comment)
    if ($null -eq $createdAt -or ($null -ne $anchor -and $createdAt -le $anchor)) {
      continue
    }

    $latestReviewId = if ($null -eq $latestReview) { $null } else { [string](Get-LoopProperty $latestReview "id") }
    $addressedReviewIds = @(Get-LoopAddressedReviewIds -Body $commentBody)
    $targetsLatestReview = $true
    if (-not [string]::IsNullOrWhiteSpace($latestReviewId) -and $addressedReviewIds.Count -gt 0) {
      $targetsLatestReview = $addressedReviewIds -contains $latestReviewId
    }

    $addressedEvents += [pscustomobject]@{
      id = Get-LoopProperty $comment "id"
      author = Get-LoopCommentAuthorLogin $comment
      url = Get-LoopCommentUrl $comment
      when = $createdAt
      reviewIds = $addressedReviewIds
      targetsLatestReview = $targetsLatestReview
    }
  }

  $latestAddressed = Get-LoopLatest $addressedEvents
  if ($null -ne $latestAddressed) {
    Complete-LoopCheck -Status "ACTION" -Event "review_addressed" -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      prUrl = Get-LoopProperty $pr "url"
      headRefOid = Get-LoopProperty $pr "headRefOid"
      reviewDecision = Get-LoopProperty $pr "reviewDecision"
      latestReviewId = if ($null -eq $latestReview) { $null } else { Get-LoopProperty $latestReview "id" }
      latestReviewState = if ($null -eq $latestReview) { $null } else { Get-LoopProperty $latestReview "state" }
      latestReviewAt = if ($null -eq $anchor) { $null } else { $anchor.ToString("o") }
      addressedCommentId = Get-LoopProperty $latestAddressed "id"
      addressedBy = Get-LoopProperty $latestAddressed "author"
      addressedUrl = Get-LoopProperty $latestAddressed "url"
      addressedAt = (Get-LoopProperty $latestAddressed "when").ToString("o")
      addressedReviewIds = @(Get-LoopProperty $latestAddressed "reviewIds")
      addressedTargetsLatestReview = Get-LoopProperty $latestAddressed "targetsLatestReview"
    }) -ExitCode 0
  }

  $rereviewRequestEvents = @()
  foreach ($comment in $comments) {
    $commentBody = Get-LoopProperty $comment "body"
    if (-not (Test-LoopBodyContains $commentBody $RereviewRequestMarker)) {
      continue
    }

    $createdAt = ConvertTo-LoopDateTimeOffset (Get-LoopCommentCreatedAt $comment)
    if ($null -eq $createdAt -or ($null -ne $anchor -and $createdAt -le $anchor)) {
      continue
    }

    $rereviewRequestEvents += [pscustomobject]@{
      id = Get-LoopProperty $comment "id"
      author = Get-LoopCommentAuthorLogin $comment
      url = Get-LoopCommentUrl $comment
      when = $createdAt
    }
  }

  $latestRereviewRequest = Get-LoopLatest $rereviewRequestEvents
  if ($null -ne $latestRereviewRequest) {
    Complete-LoopCheck -Status "ACTION" -Event "rereview_requested" -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      prUrl = Get-LoopProperty $pr "url"
      headRefOid = Get-LoopProperty $pr "headRefOid"
      reviewDecision = Get-LoopProperty $pr "reviewDecision"
      latestReviewId = if ($null -eq $latestReview) { $null } else { Get-LoopProperty $latestReview "id" }
      latestReviewState = if ($null -eq $latestReview) { $null } else { Get-LoopProperty $latestReview "state" }
      latestReviewAt = if ($null -eq $anchor) { $null } else { $anchor.ToString("o") }
      requestCommentId = Get-LoopProperty $latestRereviewRequest "id"
      requestedBy = Get-LoopProperty $latestRereviewRequest "author"
      requestUrl = Get-LoopProperty $latestRereviewRequest "url"
      requestedAt = (Get-LoopProperty $latestRereviewRequest "when").ToString("o")
    }) -ExitCode 0
  }

  $headRefOid = [string](Get-LoopProperty $pr "headRefOid")
  $latestReviewCommit = if ($null -eq $latestReview) { $null } else { [string](Get-LoopProperty $latestReview "commit") }
  $reviewedHeadAnchor = if ([string]::IsNullOrWhiteSpace($ReviewedHeadRefOid)) { $latestReviewCommit } else { $ReviewedHeadRefOid }
  if (-not [string]::IsNullOrWhiteSpace($reviewedHeadAnchor) -and $reviewedHeadAnchor -ne $headRefOid) {
    $headChangeObservedAt = ConvertTo-LoopDateTimeOffset (Get-LoopProperty $pr "updatedAt")
    if ($HeadChangeGraceSeconds -gt 0 -and $null -ne $headChangeObservedAt) {
      $headChangeAgeSeconds = [int][Math]::Max(0, [Math]::Floor(([DateTimeOffset]::UtcNow - $headChangeObservedAt).TotalSeconds))
      if ($headChangeAgeSeconds -lt $HeadChangeGraceSeconds) {
        Complete-LoopCheck -Status "WAIT" -Event "head_changed_waiting_for_addressed_comment_grace" -Data ([ordered]@{
          repo = $Repo
          pullRequest = $PullRequest
          prUrl = Get-LoopProperty $pr "url"
          headRefOid = $headRefOid
          reviewDecision = Get-LoopProperty $pr "reviewDecision"
          latestReviewId = if ($null -eq $latestReview) { $null } else { Get-LoopProperty $latestReview "id" }
          latestReviewState = if ($null -eq $latestReview) { $null } else { Get-LoopProperty $latestReview "state" }
          latestReviewAt = if ($null -eq $anchor) { $null } else { $anchor.ToString("o") }
          latestReviewCommit = $latestReviewCommit
          reviewedHeadRefOid = $reviewedHeadAnchor
          addressedCommentCount = $addressedEvents.Count
          headChangeObservedAt = $headChangeObservedAt.ToString("o")
          headChangeGraceSeconds = $HeadChangeGraceSeconds
          headChangeGraceRemainingSeconds = $HeadChangeGraceSeconds - $headChangeAgeSeconds
        }) -ExitCode $script:LoopRetryExitCode
      }
    }

    Complete-LoopCheck -Status "ACTION" -Event "head_changed_after_latest_review" -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      prUrl = Get-LoopProperty $pr "url"
      headRefOid = $headRefOid
      reviewDecision = Get-LoopProperty $pr "reviewDecision"
      latestReviewId = if ($null -eq $latestReview) { $null } else { Get-LoopProperty $latestReview "id" }
      latestReviewState = if ($null -eq $latestReview) { $null } else { Get-LoopProperty $latestReview "state" }
      latestReviewAt = if ($null -eq $anchor) { $null } else { $anchor.ToString("o") }
      latestReviewCommit = $latestReviewCommit
      reviewedHeadRefOid = $reviewedHeadAnchor
      addressedCommentCount = $addressedEvents.Count
    }) -ExitCode 0
  }

  Complete-LoopCheck -Status "WAIT" -Event "awaiting_implementer_addressed_comment" -Data ([ordered]@{
    repo = $Repo
    pullRequest = $PullRequest
    prUrl = Get-LoopProperty $pr "url"
    headRefOid = Get-LoopProperty $pr "headRefOid"
    reviewDecision = Get-LoopProperty $pr "reviewDecision"
    latestReviewId = if ($null -eq $latestReview) { $null } else { Get-LoopProperty $latestReview "id" }
    latestReviewState = if ($null -eq $latestReview) { $null } else { Get-LoopProperty $latestReview "state" }
      latestReviewAt = if ($null -eq $anchor) { $null } else { $anchor.ToString("o") }
      reviewedHeadRefOid = if ([string]::IsNullOrWhiteSpace($ReviewedHeadRefOid)) { $null } else { $ReviewedHeadRefOid }
      addressedCommentCount = $addressedEvents.Count
      rereviewRequestCount = $rereviewRequestEvents.Count
    }) -ExitCode $script:LoopRetryExitCode
  }
catch {
  Complete-LoopGitHubError -Data ([ordered]@{
    repo = $Repo
    pullRequest = $PullRequest
    ghUser = $GhUser
  }) -ErrorMessage $_.Exception.Message
}
