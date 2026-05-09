#!/usr/bin/env bash
set -euo pipefail

PR_NUMBER=""
REPO_ARGS=()
REQUIRE_REVIEW=0

usage() {
  cat <<'EOF'
Usage:
  check-pr-ready.sh --pr NUMBER [--repo OWNER/REPO] [--require-review]

Checks whether a GitHub pull request is ready to merge.

Exit codes:
  0   Ready to merge, or already merged.
  10  Waiting for review/checks/mergeability.
  11  Branch is behind the base branch.
  20  CI/status checks are failing.
  21  Merge conflicts detected.
  22  PR is closed without being merged.
  23  GitHub CLI/auth/API error.
  24  Changes requested in review.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pr)
      [ "$#" -ge 2 ] || { echo "--pr requires a number" >&2; exit 23; }
      PR_NUMBER="$2"
      shift 2
      ;;
    --repo)
      [ "$#" -ge 2 ] || { echo "--repo requires OWNER/REPO" >&2; exit 23; }
      REPO_ARGS=(--repo "$2")
      shift 2
      ;;
    --require-review)
      REQUIRE_REVIEW=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 23
      ;;
  esac
done

[ -n "$PR_NUMBER" ] || { echo "--pr is required" >&2; exit 23; }

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required to check PR readiness" >&2
  exit 23
fi

data="$(gh pr view "$PR_NUMBER" "${REPO_ARGS[@]}" \
  --json state,isDraft,reviewDecision,mergeStateStatus,mergeable,headRefOid,url \
  --jq '[.state, (.isDraft | tostring), (.reviewDecision // "null"), (.mergeStateStatus // "UNKNOWN"), (.mergeable // "UNKNOWN"), (.headRefOid // ""), (.url // "")] | @tsv' 2>/dev/null)" || {
  echo "failed to read PR #${PR_NUMBER}; check gh auth status and repository access" >&2
  exit 23
}

IFS=$'\t' read -r state is_draft review merge_state mergeable head_sha url <<EOF
$data
EOF

printf 'pr=%s state=%s draft=%s review=%s mergeStateStatus=%s mergeable=%s head=%s url=%s\n' \
  "$PR_NUMBER" "$state" "$is_draft" "$review" "$merge_state" "$mergeable" "$head_sha" "$url"

case "$state" in
  MERGED)
    echo "PR is already merged"
    exit 0
    ;;
  CLOSED)
    echo "PR is closed without being merged" >&2
    exit 22
    ;;
esac

if [ "$is_draft" = "true" ] || [ "$merge_state" = "DRAFT" ]; then
  echo "PR is a draft; waiting"
  exit 10
fi

if [ "$mergeable" = "UNKNOWN" ] || [ "$merge_state" = "UNKNOWN" ]; then
  echo "GitHub is still computing mergeability; waiting"
  exit 10
fi

if [ "$mergeable" = "CONFLICTING" ] || [ "$merge_state" = "DIRTY" ]; then
  echo "Merge conflicts detected" >&2
  exit 21
fi

if [ "$merge_state" = "BEHIND" ]; then
  echo "Branch is behind the base branch" >&2
  exit 11
fi

if [ "$review" = "CHANGES_REQUESTED" ]; then
  echo "Review changes requested" >&2
  exit 24
fi

if [ "$merge_state" = "UNSTABLE" ]; then
  echo "Status checks are failing" >&2
  gh pr checks "$PR_NUMBER" "${REPO_ARGS[@]}" --required --json name,bucket,link \
    --jq '.[] | select(.bucket == "fail") | "failed_check=\(.name) link=\(.link)"' 2>/dev/null || true
  exit 20
fi

if [ "$merge_state" = "BLOCKED" ]; then
  checks_exit=0
  gh pr checks "$PR_NUMBER" "${REPO_ARGS[@]}" --required >/dev/null 2>&1 || checks_exit=$?
  case "$checks_exit" in
    1)
      echo "Required status checks are failing" >&2
      gh pr checks "$PR_NUMBER" "${REPO_ARGS[@]}" --required --json name,bucket,link \
        --jq '.[] | select(.bucket == "fail") | "failed_check=\(.name) link=\(.link)"' 2>/dev/null || true
      exit 20
      ;;
    8)
      echo "Required status checks are still pending"
      exit 10
      ;;
  esac

  if [ "$review" = "REVIEW_REQUIRED" ] || { [ "$REQUIRE_REVIEW" -eq 1 ] && [ "$review" != "APPROVED" ]; }; then
    echo "Review approval is still required"
    exit 10
  fi

  echo "PR is blocked by branch protection or merge queue; waiting"
  exit 10
fi

if [ "$merge_state" = "CLEAN" ] || [ "$merge_state" = "HAS_HOOKS" ]; then
  if [ "$review" = "APPROVED" ] || { [ "$REQUIRE_REVIEW" -eq 0 ] && [ "$review" = "null" ]; }; then
    echo "PR is ready to merge"
    printf 'match_head_commit=%s\n' "$head_sha"
    exit 0
  fi

  echo "PR is mergeable, but approval is still required"
  exit 10
fi

echo "Unhandled merge state: $merge_state; waiting"
exit 10
