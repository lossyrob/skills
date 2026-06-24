param(
  [Parameter(Mandatory)]
  [string]$OrganizationUrl,

  [Parameter(Mandatory)]
  [string]$Project,

  [Parameter(Mandatory)]
  [string]$Repository,

  [Parameter(Mandatory)]
  [Alias("Pr")]
  [int]$PullRequest,

  [string]$Since,

  [string]$ReviewedHeadRefOid,

  [string]$ReviewerUniqueName,

  [string]$AddressedMarker = "PAW Implementer: Review Addressed",

  [string]$RereviewRequestMarker = "PAW Implementer: Re-review Requested",

  [string]$ApprovalMarker = "PAW Review: +1",

  [ValidateRange(0, [int]::MaxValue)]
  [int]$HeadChangeGraceSeconds = 120
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "github-loop-common.ps1")

function Get-AdoOrganizationUrl {
  param(
    [Parameter(Mandatory)]
    [string]$Value
  )

  $text = $Value.Trim().TrimEnd("/")
  if ($text -match "^https?://") {
    return $text
  }

  return "https://dev.azure.com/$text"
}

function Get-AdoOrganizationName {
  param(
    [Parameter(Mandatory)]
    [string]$Value
  )

  $uri = [Uri](Get-AdoOrganizationUrl $Value)
  if ($uri.Host -ieq "dev.azure.com") {
    return $uri.AbsolutePath.Trim("/").Split("/")[0]
  }

  return $uri.Host.Split(".")[0]
}

function Get-AdoAuthorizationHeader {
  param(
    [Parameter(Mandatory)]
    [string]$Organization,

    [Parameter(Mandatory)]
    [string]$ProjectName,

    [Parameter(Mandatory)]
    [string]$RepositoryName
  )

  $projectPath = [uri]::EscapeDataString($ProjectName)
  $credentialInput = "protocol=https`nhost=dev.azure.com`npath=$Organization/$projectPath/_git/$RepositoryName`n`n"
  $credentialOutput = $credentialInput | git credential fill
  $credential = @{}
  foreach ($line in $credentialOutput) {
    if ($line -match "^(.*?)=(.*)$") {
      $credential[$matches[1]] = $matches[2]
    }
  }

  if (-not $credential.ContainsKey("password")) {
    throw "git credential fill did not return an Azure DevOps token for $Organization/$ProjectName/_git/$RepositoryName."
  }

  $user = if ($credential.ContainsKey("username")) { $credential["username"] } else { "" }
  $pair = "{0}:{1}" -f $user, $credential["password"]
  return "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($pair)))"
}

function Get-AdoErrorStatusCode {
  param(
    [Parameter(Mandatory)]
    [object]$ErrorRecord
  )

  $response = Get-LoopProperty (Get-LoopProperty $ErrorRecord "Exception") "Response"
  if ($null -ne $response) {
    $statusCode = Get-LoopProperty $response "StatusCode"
    if ($null -ne $statusCode) {
      return [int]$statusCode
    }
  }

  $message = [string](Get-LoopProperty (Get-LoopProperty $ErrorRecord "Exception") "Message")
  if ($message -match "Response status code does not indicate success:\s*(?<code>\d{3})") {
    return [int]$matches["code"]
  }

  return $null
}

function Test-AdoTransientError {
  param(
    [Parameter(Mandatory)]
    [object]$ErrorRecord
  )

  $statusCode = Get-AdoErrorStatusCode -ErrorRecord $ErrorRecord
  if ($statusCode -in @(408, 429, 500, 502, 503, 504)) {
    return $true
  }

  $message = [string](Get-LoopProperty (Get-LoopProperty $ErrorRecord "Exception") "Message")
  return $message -match "(?i)(timeout|timed out|connection reset|connection refused|temporarily unavailable|service unavailable|gateway timeout)"
}

function Invoke-AdoJson {
  param(
    [Parameter(Mandatory)]
    [string]$Uri,

    [Parameter(Mandatory)]
    [hashtable]$Headers,

    [int]$MaxAttempts = 3,

    [int]$RetryDelaySeconds = 2
  )

  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    try {
      return Invoke-RestMethod -Headers $Headers -Uri $Uri -Method Get -TimeoutSec 30
    }
    catch {
      if ($attempt -lt $MaxAttempts -and (Test-AdoTransientError -ErrorRecord $_)) {
        Start-Sleep -Seconds ([Math]::Min(15, $RetryDelaySeconds * $attempt))
        continue
      }

      throw
    }
  }

  throw "Azure DevOps request failed after $MaxAttempts attempts: $Uri"
}

function Get-AdoCommentEvents {
  param(
    [AllowNull()]
    [object[]]$Threads
  )

  $events = @()
  foreach ($thread in (ConvertTo-LoopArray $Threads)) {
    foreach ($comment in (ConvertTo-LoopArray (Get-LoopProperty $thread "comments"))) {
      $createdAt = ConvertTo-LoopDateTimeOffset (Get-LoopProperty $comment "publishedDate")
      if ($null -eq $createdAt) {
        continue
      }

      $author = Get-LoopProperty (Get-LoopProperty $comment "author") "uniqueName"
      $selfLink = Get-LoopProperty (Get-LoopProperty (Get-LoopProperty $comment "_links") "self") "href"
      $events += [pscustomobject]@{
        id = Get-LoopProperty $comment "id"
        threadId = Get-LoopProperty $thread "id"
        author = $author
        url = $selfLink
        body = Get-LoopProperty $comment "content"
        when = $createdAt
      }
    }
  }

  return ,@($events)
}

try {
  $orgUrl = Get-AdoOrganizationUrl $OrganizationUrl
  $orgName = Get-AdoOrganizationName $OrganizationUrl
  $projectPath = [uri]::EscapeDataString($Project)
  $headers = @{ Authorization = Get-AdoAuthorizationHeader -Organization $orgName -ProjectName $Project -RepositoryName $Repository }
  $baseUri = "$orgUrl/$projectPath/_apis/git/repositories/$Repository/pullRequests/$PullRequest"

  $pr = Invoke-AdoJson -Headers $headers -Uri "$baseUri`?api-version=7.1"
  $threadsResponse = Invoke-AdoJson -Headers $headers -Uri "$baseUri/threads`?api-version=7.1"
  $iterationsResponse = Invoke-AdoJson -Headers $headers -Uri "$baseUri/iterations`?api-version=7.1"

  $status = [string](Get-LoopProperty $pr "status")
  $prUrl = "$orgUrl/$projectPath/_git/$Repository/pullrequest/$PullRequest"
  $headRefOid = [string](Get-LoopProperty (Get-LoopProperty $pr "lastMergeSourceCommit") "commitId")
  $reviewDecision = [string](Get-LoopProperty $pr "mergeStatus")

  if ($status -eq "completed") {
    Complete-LoopCheck -Status "ACTION" -Event "already_merged" -Data ([ordered]@{
      provider = "azure-devops"
      organizationUrl = $orgUrl
      project = $Project
      repository = $Repository
      pullRequest = $PullRequest
      prUrl = $prUrl
      headRefOid = $headRefOid
    }) -ExitCode 0
  }

  if ($status -eq "abandoned") {
    Complete-LoopCheck -Status "STOP" -Event "closed_unmerged" -Data ([ordered]@{
      provider = "azure-devops"
      organizationUrl = $orgUrl
      project = $Project
      repository = $Repository
      pullRequest = $PullRequest
      prUrl = $prUrl
      headRefOid = $headRefOid
    }) -ExitCode $script:LoopStopExitCode
  }

  $comments = Get-AdoCommentEvents -Threads (Get-LoopProperty $threadsResponse "value")
  $reviewEvents = @()
  foreach ($comment in $comments) {
    if (-not (Test-LoopBodyStartsWithMarker (Get-LoopProperty $comment "body") $ApprovalMarker)) {
      continue
    }

    if (-not [string]::IsNullOrWhiteSpace($ReviewerUniqueName) -and
        -not [string]::Equals([string](Get-LoopProperty $comment "author"), $ReviewerUniqueName, [StringComparison]::OrdinalIgnoreCase)) {
      continue
    }

    $reviewEvents += [pscustomobject]@{
      id = Get-LoopProperty $comment "id"
      threadId = Get-LoopProperty $comment "threadId"
      author = Get-LoopProperty $comment "author"
      url = Get-LoopProperty $comment "url"
      when = Get-LoopProperty $comment "when"
    }
  }

  $latestReview = Get-LoopLatest $reviewEvents
  $anchor = ConvertTo-LoopDateTimeOffset $Since
  if ($null -ne $latestReview) {
    $latestReviewAt = Get-LoopProperty $latestReview "when"
    if ($null -eq $anchor -or $latestReviewAt -gt $anchor) {
      $anchor = $latestReviewAt
    }
  }

  $addressedEvents = @()
  foreach ($comment in $comments) {
    if (-not (Test-LoopBodyContains (Get-LoopProperty $comment "body") $AddressedMarker)) {
      continue
    }

    $createdAt = Get-LoopProperty $comment "when"
    if ($null -eq $createdAt -or ($null -ne $anchor -and $createdAt -le $anchor)) {
      continue
    }

    $addressedEvents += $comment
  }

  $latestAddressed = Get-LoopLatest $addressedEvents
  if ($null -ne $latestAddressed) {
    Complete-LoopCheck -Status "ACTION" -Event "review_addressed" -Data ([ordered]@{
      provider = "azure-devops"
      organizationUrl = $orgUrl
      project = $Project
      repository = $Repository
      pullRequest = $PullRequest
      prUrl = $prUrl
      headRefOid = $headRefOid
      reviewDecision = $reviewDecision
      latestReviewId = if ($null -eq $latestReview) { $null } else { Get-LoopProperty $latestReview "id" }
      latestReviewAt = if ($null -eq $anchor) { $null } else { $anchor.ToString("o") }
      addressedCommentId = Get-LoopProperty $latestAddressed "id"
      addressedThreadId = Get-LoopProperty $latestAddressed "threadId"
      addressedBy = Get-LoopProperty $latestAddressed "author"
      addressedUrl = Get-LoopProperty $latestAddressed "url"
      addressedAt = (Get-LoopProperty $latestAddressed "when").ToString("o")
    }) -ExitCode 0
  }

  $rereviewRequestEvents = @()
  foreach ($comment in $comments) {
    if (-not (Test-LoopBodyContains (Get-LoopProperty $comment "body") $RereviewRequestMarker)) {
      continue
    }

    $createdAt = Get-LoopProperty $comment "when"
    if ($null -eq $createdAt -or ($null -ne $anchor -and $createdAt -le $anchor)) {
      continue
    }

    $rereviewRequestEvents += $comment
  }

  $latestRereviewRequest = Get-LoopLatest $rereviewRequestEvents
  if ($null -ne $latestRereviewRequest) {
    Complete-LoopCheck -Status "ACTION" -Event "rereview_requested" -Data ([ordered]@{
      provider = "azure-devops"
      organizationUrl = $orgUrl
      project = $Project
      repository = $Repository
      pullRequest = $PullRequest
      prUrl = $prUrl
      headRefOid = $headRefOid
      reviewDecision = $reviewDecision
      latestReviewId = if ($null -eq $latestReview) { $null } else { Get-LoopProperty $latestReview "id" }
      latestReviewAt = if ($null -eq $anchor) { $null } else { $anchor.ToString("o") }
      requestCommentId = Get-LoopProperty $latestRereviewRequest "id"
      requestThreadId = Get-LoopProperty $latestRereviewRequest "threadId"
      requestedBy = Get-LoopProperty $latestRereviewRequest "author"
      requestUrl = Get-LoopProperty $latestRereviewRequest "url"
      requestedAt = (Get-LoopProperty $latestRereviewRequest "when").ToString("o")
    }) -ExitCode 0
  }

  $reviewedHeadAnchor = if ([string]::IsNullOrWhiteSpace($ReviewedHeadRefOid)) { $null } else { $ReviewedHeadRefOid }
  if (-not [string]::IsNullOrWhiteSpace($reviewedHeadAnchor) -and $reviewedHeadAnchor -ne $headRefOid) {
    $latestIteration = Get-LoopLatest (@(ConvertTo-LoopArray (Get-LoopProperty $iterationsResponse "value")) | ForEach-Object {
      [pscustomobject]@{
        id = Get-LoopProperty $_ "id"
        when = ConvertTo-LoopDateTimeOffset (Get-LoopProperty $_ "createdDate")
        sourceCommit = Get-LoopProperty (Get-LoopProperty $_ "sourceRefCommit") "commitId"
      }
    })

    $headChangeObservedAt = if ($null -eq $latestIteration) { $null } else { Get-LoopProperty $latestIteration "when" }
    if ($HeadChangeGraceSeconds -gt 0 -and $null -ne $headChangeObservedAt) {
      $headChangeAgeSeconds = [int][Math]::Max(0, [Math]::Floor(([DateTimeOffset]::UtcNow - $headChangeObservedAt).TotalSeconds))
      if ($headChangeAgeSeconds -lt $HeadChangeGraceSeconds) {
        Complete-LoopCheck -Status "WAIT" -Event "head_changed_waiting_for_addressed_comment_grace" -Data ([ordered]@{
          provider = "azure-devops"
          organizationUrl = $orgUrl
          project = $Project
          repository = $Repository
          pullRequest = $PullRequest
          prUrl = $prUrl
          headRefOid = $headRefOid
          reviewDecision = $reviewDecision
          latestReviewId = if ($null -eq $latestReview) { $null } else { Get-LoopProperty $latestReview "id" }
          latestReviewAt = if ($null -eq $anchor) { $null } else { $anchor.ToString("o") }
          reviewedHeadRefOid = $reviewedHeadAnchor
          addressedCommentCount = $addressedEvents.Count
          rereviewRequestCount = $rereviewRequestEvents.Count
          headChangeObservedAt = $headChangeObservedAt.ToString("o")
          headChangeGraceSeconds = $HeadChangeGraceSeconds
          headChangeGraceRemainingSeconds = $HeadChangeGraceSeconds - $headChangeAgeSeconds
        }) -ExitCode $script:LoopRetryExitCode
      }
    }

    Complete-LoopCheck -Status "ACTION" -Event "head_changed_after_latest_review" -Data ([ordered]@{
      provider = "azure-devops"
      organizationUrl = $orgUrl
      project = $Project
      repository = $Repository
      pullRequest = $PullRequest
      prUrl = $prUrl
      headRefOid = $headRefOid
      reviewDecision = $reviewDecision
      latestReviewId = if ($null -eq $latestReview) { $null } else { Get-LoopProperty $latestReview "id" }
      latestReviewAt = if ($null -eq $anchor) { $null } else { $anchor.ToString("o") }
      reviewedHeadRefOid = $reviewedHeadAnchor
      addressedCommentCount = $addressedEvents.Count
      rereviewRequestCount = $rereviewRequestEvents.Count
    }) -ExitCode 0
  }

  Complete-LoopCheck -Status "WAIT" -Event "awaiting_implementer_addressed_comment" -Data ([ordered]@{
    provider = "azure-devops"
    organizationUrl = $orgUrl
    project = $Project
    repository = $Repository
    pullRequest = $PullRequest
    prUrl = $prUrl
    headRefOid = $headRefOid
    reviewDecision = $reviewDecision
    latestReviewId = if ($null -eq $latestReview) { $null } else { Get-LoopProperty $latestReview "id" }
    latestReviewAt = if ($null -eq $anchor) { $null } else { $anchor.ToString("o") }
    reviewedHeadRefOid = $reviewedHeadAnchor
    addressedCommentCount = $addressedEvents.Count
    rereviewRequestCount = $rereviewRequestEvents.Count
  }) -ExitCode $script:LoopRetryExitCode
}
catch {
  if (Test-AdoTransientError -ErrorRecord $_) {
    Complete-LoopCheck -Status "WAIT" -Event "azdo_api_transient_error" -Data ([ordered]@{
      provider = "azure-devops"
      organizationUrl = $OrganizationUrl
      project = $Project
      repository = $Repository
      pullRequest = $PullRequest
      error = $_.Exception.Message
      statusCode = Get-AdoErrorStatusCode -ErrorRecord $_
    }) -ExitCode $script:LoopRetryExitCode
  }

  Complete-LoopCheck -Status "STOP" -Event "script_or_azdo_api_error" -Data ([ordered]@{
    provider = "azure-devops"
    organizationUrl = $OrganizationUrl
    project = $Project
    repository = $Repository
    pullRequest = $PullRequest
    error = $_.Exception.Message
  }) -ExitCode $script:LoopStopExitCode
}
