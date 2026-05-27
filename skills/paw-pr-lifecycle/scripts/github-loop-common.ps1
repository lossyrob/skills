Set-StrictMode -Version 3.0

$script:LoopRetryExitCode = 10
$script:LoopStopExitCode = 23
$script:LoopGhToken = $null

function Test-LoopTransientGhError {
  param(
    [AllowNull()]
    [string]$ErrorText
  )

  if ([string]::IsNullOrWhiteSpace($ErrorText)) {
    return $false
  }

  return $ErrorText -match "(?i)(TLS handshake timeout|timeout|timed out|connection reset|connection refused|network is unreachable|no such host|error connecting to api\.github\.com|check your internet connection|temporarily unavailable|502 Bad Gateway|503 Service Unavailable|504 Gateway Timeout|Could not resolve to a Repository with the name)"
}

function Test-LoopGitHubRateLimitError {
  param(
    [AllowNull()]
    [string]$ErrorText
  )

  if ([string]::IsNullOrWhiteSpace($ErrorText)) {
    return $false
  }

  return $ErrorText -match "(?i)(API rate limit exceeded|rate limit exceeded|secondary rate limit)"
}

function Invoke-GhJson {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string[]]$Arguments,

    [int]$MaxAttempts = 3,

    [int]$RetryDelaySeconds = 2
  )

  for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processInfo.FileName = "gh"
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.UseShellExecute = $false
    $processInfo.EnvironmentVariables["GH_PROMPT_DISABLED"] = "1"
    if (-not [string]::IsNullOrWhiteSpace($script:LoopGhToken)) {
      $processInfo.EnvironmentVariables["GH_TOKEN"] = $script:LoopGhToken
    }

    foreach ($argument in $Arguments) {
      [void]$processInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::Start($processInfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($process.ExitCode -eq 0) {
      if ([string]::IsNullOrWhiteSpace($stdout)) {
        return $null
      }

      return $stdout | ConvertFrom-Json -NoEnumerate
    }

    $message = "gh $($Arguments -join ' ') failed with exit code $($process.ExitCode)."
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
      $message = "$message stderr: $stderr"
    }

    if ($attempt -lt $MaxAttempts -and (Test-LoopTransientGhError $message)) {
      Start-Sleep -Seconds ([Math]::Min(15, $RetryDelaySeconds * $attempt))
      continue
    }

    throw $message
  }

  throw "gh $($Arguments -join ' ') failed after $MaxAttempts attempts."
}

function Get-LoopGhTokenForUser {
  param(
    [Parameter(Mandatory)]
    [string]$GhUser
  )

  $errors = [System.Collections.Generic.List[string]]::new()
  foreach ($attempt in 1..3) {
    $result = Invoke-LoopGhTokenCommand -Arguments @("auth", "token", "--hostname", "github.com", "--user", $GhUser)
    if ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($result.Stdout)) {
      return ([string]$result.Stdout).Trim()
    }

    [void]$errors.Add((Format-LoopGhTokenError -ExitCode $result.ExitCode -Stderr $result.Stderr))
    if ($attempt -lt 3) {
      Start-Sleep -Seconds $attempt
    }
  }

  try {
    $viewer = Invoke-GhJson -Arguments @("api", "user") -MaxAttempts 1
    $activeUser = [string](Get-LoopProperty $viewer "login")
    if ($activeUser -eq $GhUser) {
      foreach ($attempt in 1..3) {
        $result = Invoke-LoopGhTokenCommand -Arguments @("auth", "token", "--hostname", "github.com")
        if ($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($result.Stdout)) {
          return ([string]$result.Stdout).Trim()
        }

        [void]$errors.Add((Format-LoopGhTokenError -ExitCode $result.ExitCode -Stderr $result.Stderr -Fallback))
        if ($attempt -lt 3) {
          Start-Sleep -Seconds $attempt
        }
      }
    }
  }
  catch {
    [void]$errors.Add("active account fallback failed: $($_.Exception.Message)")
  }

  throw ($errors | Select-Object -Last 1)
}

function Invoke-LoopGhTokenCommand {
  param(
    [Parameter(Mandatory)]
    [string[]]$Arguments
  )

  $processInfo = [System.Diagnostics.ProcessStartInfo]::new()
  $processInfo.FileName = "gh"
  $processInfo.RedirectStandardOutput = $true
  $processInfo.RedirectStandardError = $true
  $processInfo.UseShellExecute = $false
  $processInfo.EnvironmentVariables["GH_PROMPT_DISABLED"] = "1"

  foreach ($argument in $Arguments) {
    [void]$processInfo.ArgumentList.Add($argument)
  }

  $process = [System.Diagnostics.Process]::Start($processInfo)
  $stdout = $process.StandardOutput.ReadToEnd()
  $stderr = $process.StandardError.ReadToEnd()
  $process.WaitForExit()

  return [pscustomobject]@{
    ExitCode = $process.ExitCode
    Stdout = $stdout
    Stderr = $stderr
  }
}

function Format-LoopGhTokenError {
  param(
    [Parameter(Mandatory)]
    [int]$ExitCode,

    [AllowNull()]
    [string]$Stderr,

    [switch]$Fallback
  )

  $mode = if ($Fallback) { "active account fallback" } else { "--user <redacted>" }
  $message = "gh auth token --hostname github.com $mode failed with exit code $ExitCode."
  if (-not [string]::IsNullOrWhiteSpace($Stderr)) {
    $message = "$message stderr: $Stderr"
  }

  return $message
}

function Get-LoopCacheDirectory {
  $cacheDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "github-paw-pr-lifecycle-cache"
  if (-not (Test-Path -LiteralPath $cacheDirectory)) {
    [void](New-Item -ItemType Directory -Force -Path $cacheDirectory)
  }

  return $cacheDirectory
}

function ConvertTo-LoopArray {
  param(
    [AllowNull()]
    [object]$Value
  )

  if ($null -eq $Value) {
    return ,@()
  }

  if ($Value -is [System.Array]) {
    return ,@($Value)
  }

  return ,@($Value)
}

function Get-LoopProperty {
  param(
    [AllowNull()]
    [object]$InputObject,

    [Parameter(Mandatory)]
    [string]$Name
  )

  if ($null -eq $InputObject) {
    return $null
  }

  $property = $InputObject.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }

  return $property.Value
}

function ConvertTo-LoopDateTimeOffset {
  param(
    [AllowNull()]
    [object]$Value
  )

  if ($null -eq $Value) {
    return $null
  }

  $text = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $null
  }

  return [DateTimeOffset]::Parse(
    $text,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
  )
}

function Get-LoopGitHubRateLimitResetAt {
  try {
    $rateLimit = Invoke-GhJson -Arguments @("api", "rate_limit") -MaxAttempts 1
    $resources = Get-LoopProperty $rateLimit "resources"
    $core = Get-LoopProperty $resources "core"
    $reset = Get-LoopProperty $core "reset"
    if ($null -eq $reset) {
      return $null
    }

    return [DateTimeOffset]::FromUnixTimeSeconds([int64]$reset).ToUniversalTime()
  }
  catch {
    return $null
  }
}

function Get-LoopCommentCreatedAt {
  param(
    [AllowNull()]
    [object]$Comment
  )

  $createdAt = Get-LoopProperty $Comment "created_at"
  if ($null -eq $createdAt) {
    $createdAt = Get-LoopProperty $Comment "createdAt"
  }

  return $createdAt
}

function Get-LoopCommentUrl {
  param(
    [AllowNull()]
    [object]$Comment
  )

  $url = Get-LoopProperty $Comment "html_url"
  if ($null -eq $url) {
    $url = Get-LoopProperty $Comment "url"
  }

  return $url
}

function Get-LoopCommentAuthorLogin {
  param(
    [AllowNull()]
    [object]$Comment
  )

  $user = Get-LoopProperty $Comment "user"
  if ($null -eq $user) {
    $user = Get-LoopProperty $Comment "author"
  }

  return Get-LoopProperty $user "login"
}

function Test-LoopBodyContains {
  param(
    [AllowNull()]
    [object]$Body,

    [Parameter(Mandatory)]
    [string]$Marker
  )

  if ($null -eq $Body) {
    return $false
  }

  return ([string]$Body).IndexOf($Marker, [StringComparison]::OrdinalIgnoreCase) -ge 0
}

function Remove-LoopLeadingDecoration {
  param(
    [Parameter(Mandatory)]
    [string]$Text
  )

  if ([string]::IsNullOrEmpty($Text)) {
    return $Text
  }

  # Skip a bounded leading run of non-ASCII or non-alphanumeric ASCII characters
  # so the ASCII portion of a PAW marker still matches even when the leading
  # emoji has been corrupted into mojibake (e.g., the 4 UTF-8 bytes of U+1F43E
  # rendered as '≡ƒÉ╛' via cp437 or 'ðŸ¾' via cp1252 by a non-UTF-8 console),
  # or when the body starts with a different decorative emoji entirely. The
  # 8-code-unit bound prevents this from drifting into legitimate body text.
  $maxSkip = [Math]::Min(8, $Text.Length)
  $i = 0
  while ($i -lt $maxSkip) {
    $c = $Text[$i]
    $code = [int]$c
    if ($code -lt 0x80 -and [char]::IsLetterOrDigit($c)) {
      break
    }
    $i++
  }

  if ($i -eq 0) {
    return $Text
  }

  return $Text.Substring($i).TrimStart()
}

function Test-LoopBodyStartsWithMarker {
  param(
    [AllowNull()]
    [object]$Body,

    [Parameter(Mandatory)]
    [string]$Marker
  )

  if ($null -eq $Body) {
    return $false
  }

  $text = ([string]$Body).TrimStart()
  $markerText = $Marker.TrimStart()
  if ([string]::IsNullOrWhiteSpace($text) -or [string]::IsNullOrWhiteSpace($markerText)) {
    return $false
  }

  $text       = Remove-LoopLeadingDecoration -Text $text
  $markerText = Remove-LoopLeadingDecoration -Text $markerText

  if (-not $text.StartsWith($markerText, [StringComparison]::OrdinalIgnoreCase)) {
    return $false
  }

  if ($text.Length -eq $markerText.Length) {
    return $true
  }

  $nextCharacter = $text[$markerText.Length]
  return [char]::IsWhiteSpace($nextCharacter) -or [char]::IsPunctuation($nextCharacter)
}

function Get-LoopLatest {
  param(
    [AllowNull()]
    [object[]]$Items
  )

  $latest = $null
  foreach ($item in (ConvertTo-LoopArray $Items)) {
    $when = Get-LoopProperty $item "when"
    if ($null -eq $when) {
      continue
    }

    if ($null -eq $latest -or $when -gt (Get-LoopProperty $latest "when")) {
      $latest = $item
    }
  }

  return $latest
}

function Get-LoopPullRequest {
  param(
    [Parameter(Mandatory)]
    [string]$Repo,

    [Parameter(Mandatory)]
    [int]$PullRequest,

    [Parameter(Mandatory)]
    [string]$Fields
  )

  return Invoke-GhJson -Arguments @(
    "pr",
    "view",
    [string]$PullRequest,
    "--repo",
    $Repo,
    "--json",
    $Fields
  )
}

function Get-LoopPullRequestReviewComments {
  param(
    [Parameter(Mandatory)]
    [string]$Repo,

    [Parameter(Mandatory)]
    [int]$PullRequest
  )

  return Invoke-GhJson -Arguments @(
    "api",
    "repos/$Repo/pulls/$PullRequest/comments",
    "--method",
    "GET",
    "-F",
    "per_page=100",
    "--paginate"
  )
}

function Get-LoopIssueComments {
  param(
    [Parameter(Mandatory)]
    [string]$Repo,

    [Parameter(Mandatory)]
    [int]$IssueOrPullRequest
  )

  return Invoke-GhJson -Arguments @(
    "api",
    "repos/$Repo/issues/$IssueOrPullRequest/comments",
    "--method",
    "GET",
    "-F",
    "per_page=100",
    "--paginate"
  )
}

function Assert-LoopGhUser {
  param(
    [string]$GhUser
  )

  if ([string]::IsNullOrWhiteSpace($GhUser)) {
    return
  }

  $script:LoopGhToken = Get-LoopGhTokenForUser -GhUser $GhUser

  $cachePath = Join-Path (Get-LoopCacheDirectory) "authenticated-user.txt"
  try {
    if (Test-Path -LiteralPath $cachePath) {
      $cacheItem = Get-Item -LiteralPath $cachePath
      if ($cacheItem.LastWriteTimeUtc -gt (Get-Date).ToUniversalTime().AddMinutes(-10)) {
        $cached = (Get-Content -LiteralPath $cachePath -Raw).Trim()
        if ($cached -eq $GhUser) {
          return
        }
      }
    }
  }
  catch {
    # Fall through to the authoritative GitHub check.
  }

  $viewer = Invoke-GhJson -Arguments @("api", "user")
  $actual = [string](Get-LoopProperty $viewer "login")
  if ($actual -ne $GhUser) {
    throw "GitHub authentication user '$actual' does not match required -GhUser '$GhUser'."
  }

  try {
    Set-Content -LiteralPath $cachePath -Value $actual -Encoding utf8
  }
  catch {
    # Cache writes are best-effort; authentication has already been verified.
  }
}

function Complete-LoopCheck {
  param(
    [Parameter(Mandatory)]
    [ValidateSet("ACTION", "WAIT", "STOP")]
    [string]$Status,

    [Parameter(Mandatory)]
    [string]$Event,

    [Parameter(Mandatory)]
    [System.Collections.IDictionary]$Data,

    [Parameter(Mandatory)]
    [int]$ExitCode
  )

  $result = [ordered]@{
    status = $Status
    event = $Event
  }

  foreach ($key in $Data.Keys) {
    $result[$key] = $Data[$key]
  }

  $result | ConvertTo-Json -Depth 12 -Compress
  exit $ExitCode
}

function Complete-LoopGitHubError {
  param(
    [Parameter(Mandatory)]
    [System.Collections.IDictionary]$Data,

    [Parameter(Mandatory)]
    [string]$ErrorMessage
  )

  $errorData = [ordered]@{}
  foreach ($key in $Data.Keys) {
    $errorData[$key] = $Data[$key]
  }
  $errorData["error"] = $ErrorMessage

  if (Test-LoopGitHubRateLimitError $ErrorMessage) {
    $resetAt = Get-LoopGitHubRateLimitResetAt
    $errorData["rateLimitResetAt"] = if ($null -eq $resetAt) { $null } else { $resetAt.ToString("o") }
    $errorData["retryAfterSeconds"] = if ($null -eq $resetAt) {
      $null
    } else {
      [Math]::Max(0, [int][Math]::Ceiling(($resetAt - [DateTimeOffset]::UtcNow).TotalSeconds))
    }

    Complete-LoopCheck -Status "WAIT" -Event "github_api_rate_limited" -Data $errorData -ExitCode $script:LoopRetryExitCode
  }

  if (Test-LoopTransientGhError $ErrorMessage) {
    Complete-LoopCheck -Status "WAIT" -Event "github_api_transient_error" -Data $errorData -ExitCode $script:LoopRetryExitCode
  }

  Complete-LoopCheck -Status "STOP" -Event "script_or_github_api_error" -Data $errorData -ExitCode $script:LoopStopExitCode
}
