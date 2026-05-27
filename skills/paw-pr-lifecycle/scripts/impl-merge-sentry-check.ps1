param(
  [Parameter(Mandatory)]
  [string]$Repo,

  [Parameter(Mandatory)]
  [Alias("Pr")]
  [int]$PullRequest,

  [string]$ApprovalMarker = "PAW Review: +1",

  [string]$GhUser
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "github-loop-common.ps1")

function Get-CheckName {
  param([object]$Check)

  $name = Get-LoopProperty $Check "name"
  if (-not [string]::IsNullOrWhiteSpace([string]$name)) {
    return [string]$name
  }

  $context = Get-LoopProperty $Check "context"
  if (-not [string]::IsNullOrWhiteSpace([string]$context)) {
    return [string]$context
  }

  return "<unnamed>"
}

function Get-MergeSentryCachePath {
  param(
    [Parameter(Mandatory)]
    [string]$Repo,

    [Parameter(Mandatory)]
    [int]$PullRequest
  )

  $safeRepo = $Repo -replace "[^A-Za-z0-9_.-]", "_"
  return (Join-Path (Get-LoopCacheDirectory) "impl-merge-sentry-$safeRepo-$PullRequest.json")
}

function Read-MergeSentryCache {
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

function Write-MergeSentryCache {
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

function Clear-MergeSentryCache {
  param(
    [Parameter(Mandatory)]
    [string]$Repo,

    [Parameter(Mandatory)]
    [int]$PullRequest
  )

  $cachePath = Get-MergeSentryCachePath -Repo $Repo -PullRequest $PullRequest
  Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
}

function Get-PostApprovalReviewEvent {
  param(
    [Parameter(Mandatory)]
    [string]$Repo,

    [Parameter(Mandatory)]
    [int]$PullRequest,

    [Parameter(Mandatory)]
    [object]$Pr,

    [Parameter(Mandatory)]
    [string]$ApprovalMarker
  )

  $prAuthor = [string](Get-LoopProperty (Get-LoopProperty $Pr "author") "login")
  $approvalEvents = @()
  foreach ($review in (ConvertTo-LoopArray (Get-LoopProperty $Pr "reviews"))) {
    $reviewState = [string](Get-LoopProperty $review "state")
    if ($reviewState -in @("PENDING", "DISMISSED")) {
      continue
    }

    $submittedAt = ConvertTo-LoopDateTimeOffset (Get-LoopProperty $review "submittedAt")
    if ($null -eq $submittedAt) {
      continue
    }

    if ($reviewState -eq "APPROVED" -or ($reviewState -eq "COMMENTED" -and (Test-LoopBodyStartsWithMarker (Get-LoopProperty $review "body") $ApprovalMarker))) {
      $approvalEvents += [pscustomobject]@{
        id = Get-LoopProperty $review "id"
        source = "pr_review"
        author = Get-LoopProperty (Get-LoopProperty $review "author") "login"
        commit = Get-LoopProperty (Get-LoopProperty $review "commit") "oid"
        when = $submittedAt
      }
    }
  }

  foreach ($comment in (ConvertTo-LoopArray (Get-LoopProperty $Pr "comments"))) {
    if (-not (Test-LoopBodyStartsWithMarker (Get-LoopProperty $comment "body") $ApprovalMarker)) {
      continue
    }

    $createdAt = ConvertTo-LoopDateTimeOffset (Get-LoopCommentCreatedAt $comment)
    if ($null -eq $createdAt) {
      continue
    }

    $author = Get-LoopCommentAuthorLogin $comment
    if (-not [string]::IsNullOrWhiteSpace($prAuthor) -and $author -eq $prAuthor) {
      continue
    }

    $approvalEvents += [pscustomobject]@{
      id = Get-LoopProperty $comment "id"
      source = "pr_comment"
      author = $author
      commit = $null
      when = $createdAt
    }
  }

  $latestApproval = Get-LoopLatest $approvalEvents
  if ($null -eq $latestApproval) {
    return $null
  }

  $latestApprovalAt = Get-LoopProperty $latestApproval "when"
  $feedbackEvents = @()
  foreach ($review in (ConvertTo-LoopArray (Get-LoopProperty $Pr "reviews"))) {
    $reviewState = [string](Get-LoopProperty $review "state")
    if ($reviewState -notin @("COMMENTED", "CHANGES_REQUESTED")) {
      continue
    }

    $submittedAt = ConvertTo-LoopDateTimeOffset (Get-LoopProperty $review "submittedAt")
    if ($null -eq $submittedAt -or $submittedAt -le $latestApprovalAt) {
      continue
    }

    $author = [string](Get-LoopProperty (Get-LoopProperty $review "author") "login")
    if (-not [string]::IsNullOrWhiteSpace($prAuthor) -and $author -eq $prAuthor) {
      continue
    }

    $feedbackEvents += [pscustomobject]@{
      id = Get-LoopProperty $review "id"
      source = "pr_review"
      state = $reviewState
      author = $author
      url = $null
      commit = Get-LoopProperty (Get-LoopProperty $review "commit") "oid"
      latestApprovalId = Get-LoopProperty $latestApproval "id"
      latestApprovalAt = $latestApprovalAt
      when = $submittedAt
    }
  }

  foreach ($comment in (ConvertTo-LoopArray (Get-LoopProperty $Pr "comments"))) {
    if (Test-LoopBodyStartsWithMarker (Get-LoopProperty $comment "body") $ApprovalMarker) {
      continue
    }

    $createdAt = ConvertTo-LoopDateTimeOffset (Get-LoopCommentCreatedAt $comment)
    if ($null -eq $createdAt -or $createdAt -le $latestApprovalAt) {
      continue
    }

    $author = Get-LoopCommentAuthorLogin $comment
    if (-not [string]::IsNullOrWhiteSpace($prAuthor) -and $author -eq $prAuthor) {
      continue
    }

    $feedbackEvents += [pscustomobject]@{
      id = Get-LoopProperty $comment "id"
      source = "pr_comment"
      state = $null
      author = $author
      url = Get-LoopCommentUrl $comment
      commit = $null
      latestApprovalId = Get-LoopProperty $latestApproval "id"
      latestApprovalAt = $latestApprovalAt
      when = $createdAt
    }
  }

  try {
    foreach ($reviewComment in (ConvertTo-LoopArray (Get-LoopPullRequestReviewComments -Repo $Repo -PullRequest $PullRequest))) {
      if (Test-LoopBodyStartsWithMarker (Get-LoopProperty $reviewComment "body") $ApprovalMarker) {
        continue
      }

      $createdAt = ConvertTo-LoopDateTimeOffset (Get-LoopProperty $reviewComment "created_at")
      if ($null -eq $createdAt -or $createdAt -le $latestApprovalAt) {
        continue
      }

      $author = [string](Get-LoopProperty (Get-LoopProperty $reviewComment "user") "login")
      if (-not [string]::IsNullOrWhiteSpace($prAuthor) -and $author -eq $prAuthor) {
        continue
      }

      $feedbackEvents += [pscustomobject]@{
        id = Get-LoopProperty $reviewComment "id"
        source = "review_thread_comment"
        state = $null
        author = $author
        url = Get-LoopProperty $reviewComment "html_url"
        commit = Get-LoopProperty $reviewComment "commit_id"
        latestApprovalId = Get-LoopProperty $latestApproval "id"
        latestApprovalAt = $latestApprovalAt
        when = $createdAt
      }
    }
  }
  catch {
    # Review summaries still catch normal PR reviews; do not make merge sentry brittle on comment API failures.
  }

  return Get-LoopLatest $feedbackEvents
}

try {
  Assert-LoopGhUser -GhUser $GhUser
  $pr = Get-LoopPullRequest `
    -Repo $Repo `
    -PullRequest $PullRequest `
    -Fields "number,title,state,isDraft,author,comments,reviews,baseRefName,headRefName,headRefOid,reviewDecision,mergeStateStatus,mergeable,statusCheckRollup,url,updatedAt"

  $state = [string](Get-LoopProperty $pr "state")
  if ($state -eq "MERGED") {
    Clear-MergeSentryCache -Repo $Repo -PullRequest $PullRequest
    Complete-LoopCheck -Status "ACTION" -Event "already_merged" -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      prUrl = Get-LoopProperty $pr "url"
    }) -ExitCode 0
  }

  if ($state -eq "CLOSED") {
    Clear-MergeSentryCache -Repo $Repo -PullRequest $PullRequest
    Complete-LoopCheck -Status "STOP" -Event "closed_unmerged" -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      prUrl = Get-LoopProperty $pr "url"
    }) -ExitCode $script:LoopStopExitCode
  }

  $checks = ConvertTo-LoopArray (Get-LoopProperty $pr "statusCheckRollup")
  $pendingChecks = @()
  $failedChecks = @()

  foreach ($check in $checks) {
    $typeName = [string](Get-LoopProperty $check "__typename")

    if ($typeName -eq "CheckRun") {
      $status = [string](Get-LoopProperty $check "status")
      $conclusion = [string](Get-LoopProperty $check "conclusion")
      if ($status -ne "COMPLETED") {
        $pendingChecks += Get-CheckName $check
        continue
      }

      if ($conclusion -in @("FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE")) {
        $failedChecks += Get-CheckName $check
      }

      continue
    }

    if ($typeName -eq "StatusContext") {
      $statusContextState = [string](Get-LoopProperty $check "state")
      if ($statusContextState -in @("PENDING", "EXPECTED")) {
        $pendingChecks += Get-CheckName $check
        continue
      }

      if ($statusContextState -in @("FAILURE", "ERROR")) {
        $failedChecks += Get-CheckName $check
      }
    }
  }

  $isDraft = [bool](Get-LoopProperty $pr "isDraft")
  $reviewDecision = [string](Get-LoopProperty $pr "reviewDecision")
  $mergeStateStatus = [string](Get-LoopProperty $pr "mergeStateStatus")
  $mergeable = [string](Get-LoopProperty $pr "mergeable")
  $baseRefName = [string](Get-LoopProperty $pr "baseRefName")

  if ($isDraft) {
    Complete-LoopCheck -Status "WAIT" -Event "draft_pr" -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      prUrl = Get-LoopProperty $pr "url"
      headRefOid = Get-LoopProperty $pr "headRefOid"
    }) -ExitCode $script:LoopRetryExitCode
  }

  if ($pendingChecks.Count -gt 0) {
    Complete-LoopCheck -Status "WAIT" -Event "checks_pending" -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      prUrl = Get-LoopProperty $pr "url"
      headRefOid = Get-LoopProperty $pr "headRefOid"
      mergeStateStatus = $mergeStateStatus
      pendingChecks = $pendingChecks
    }) -ExitCode $script:LoopRetryExitCode
  }

  if ($failedChecks.Count -gt 0 -or $mergeStateStatus -eq "UNSTABLE") {
    Clear-MergeSentryCache -Repo $Repo -PullRequest $PullRequest
    Complete-LoopCheck -Status "ACTION" -Event "ci_failed" -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      prUrl = Get-LoopProperty $pr "url"
      headRefOid = Get-LoopProperty $pr "headRefOid"
      mergeStateStatus = $mergeStateStatus
      failedChecks = $failedChecks
    }) -ExitCode 0
  }

  if ($mergeStateStatus -eq "DIRTY" -or $mergeable -eq "CONFLICTING") {
    Clear-MergeSentryCache -Repo $Repo -PullRequest $PullRequest
    Complete-LoopCheck -Status "ACTION" -Event "merge_conflict" -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      prUrl = Get-LoopProperty $pr "url"
      headRefOid = Get-LoopProperty $pr "headRefOid"
      mergeStateStatus = $mergeStateStatus
      mergeable = $mergeable
    }) -ExitCode 0
  }

  if ($reviewDecision -eq "CHANGES_REQUESTED") {
    Clear-MergeSentryCache -Repo $Repo -PullRequest $PullRequest
    Complete-LoopCheck -Status "ACTION" -Event "changes_requested" -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      prUrl = Get-LoopProperty $pr "url"
      headRefOid = Get-LoopProperty $pr "headRefOid"
      reviewDecision = $reviewDecision
    }) -ExitCode 0
  }

  if ($reviewDecision -eq "REVIEW_REQUIRED") {
    Complete-LoopCheck -Status "WAIT" -Event "awaiting_approval" -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      prUrl = Get-LoopProperty $pr "url"
      headRefOid = Get-LoopProperty $pr "headRefOid"
      reviewDecision = $reviewDecision
      mergeStateStatus = $mergeStateStatus
    }) -ExitCode $script:LoopRetryExitCode
  }

  if ($mergeStateStatus -eq "UNKNOWN" -or $mergeable -eq "UNKNOWN") {
    Complete-LoopCheck -Status "WAIT" -Event "mergeability_unknown" -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      prUrl = Get-LoopProperty $pr "url"
      headRefOid = Get-LoopProperty $pr "headRefOid"
      mergeStateStatus = $mergeStateStatus
      mergeable = $mergeable
    }) -ExitCode $script:LoopRetryExitCode
  }

  if ($mergeStateStatus -eq "BLOCKED") {
    Clear-MergeSentryCache -Repo $Repo -PullRequest $PullRequest
    Complete-LoopCheck -Status "ACTION" -Event "merge_blocked" -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      prUrl = Get-LoopProperty $pr "url"
      headRefOid = Get-LoopProperty $pr "headRefOid"
      reviewDecision = $reviewDecision
      mergeStateStatus = $mergeStateStatus
      mergeable = $mergeable
    }) -ExitCode 0
  }

  $postApprovalReview = Get-PostApprovalReviewEvent -Repo $Repo -PullRequest $PullRequest -Pr $pr -ApprovalMarker $ApprovalMarker
  if ($null -ne $postApprovalReview) {
    Clear-MergeSentryCache -Repo $Repo -PullRequest $PullRequest
    Complete-LoopCheck -Status "ACTION" -Event "post_approval_review_received" -Data ([ordered]@{
      repo = $Repo
      pullRequest = $PullRequest
      prUrl = Get-LoopProperty $pr "url"
      headRefOid = Get-LoopProperty $pr "headRefOid"
      reviewDecision = $reviewDecision
      source = Get-LoopProperty $postApprovalReview "source"
      sourceId = Get-LoopProperty $postApprovalReview "id"
      sourceState = Get-LoopProperty $postApprovalReview "state"
      sourceAuthor = Get-LoopProperty $postApprovalReview "author"
      sourceUrl = Get-LoopProperty $postApprovalReview "url"
      sourceCommit = Get-LoopProperty $postApprovalReview "commit"
      latestApprovalId = Get-LoopProperty $postApprovalReview "latestApprovalId"
      latestApprovalAt = (Get-LoopProperty $postApprovalReview "latestApprovalAt").ToString("o")
      detectedAt = (Get-LoopProperty $postApprovalReview "when").ToString("o")
    }) -ExitCode 0
  }

  $cachePath = Get-MergeSentryCachePath -Repo $Repo -PullRequest $PullRequest
  $cache = Read-MergeSentryCache -Path $cachePath
  $headRefOid = [string](Get-LoopProperty $pr "headRefOid")
  $readyAlreadyAnnounced = [string](Get-LoopProperty $cache "readyHeadRefOid") -eq $headRefOid
  $readyData = [ordered]@{
    repo = $Repo
    pullRequest = $PullRequest
    prUrl = Get-LoopProperty $pr "url"
    baseRefName = $baseRefName
    headRefName = Get-LoopProperty $pr "headRefName"
    headRefOid = $headRefOid
    reviewDecision = $reviewDecision
    mergeStateStatus = $mergeStateStatus
    mergeable = $mergeable
    readyAlreadyAnnounced = $readyAlreadyAnnounced
  }

  if ($readyAlreadyAnnounced) {
    Complete-LoopCheck -Status "WAIT" -Event "ready_to_merge" -Data $readyData -ExitCode $script:LoopRetryExitCode
  }

  Write-MergeSentryCache -Path $cachePath -Data ([ordered]@{
    repo = $Repo
    pullRequest = $PullRequest
    readyHeadRefOid = $headRefOid
    readyAnnouncedAt = (Get-Date).ToUniversalTime().ToString("o")
  })

  Complete-LoopCheck -Status "ACTION" -Event "ready_to_merge" -Data $readyData -ExitCode 0
}
catch {
  Complete-LoopGitHubError -Data ([ordered]@{
    repo = $Repo
    pullRequest = $PullRequest
    ghUser = $GhUser
  }) -ErrorMessage $_.Exception.Message
}
