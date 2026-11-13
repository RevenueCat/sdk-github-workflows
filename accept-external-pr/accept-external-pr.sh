#!/usr/bin/env bash
# Handles an `@rcgitbot accept external` comment on a fork PR:
#   1. Check the command and that the commenter has write access.
#   2. Check the PR is an open fork PR targeting the default branch.
#   3. Check a maintainer approved the commit the PR is at now.
#   4. Create `external/<author>/<pr number>` and retarget the PR to it.
#   5. Squash-merge the PR into that branch, pinned to the approved commit.
#   6. Reply with a link to open the internal PR.
# After step 5 the contributor's code is on a branch where CI has secrets.
set -euo pipefail
export LC_ALL=C

REPO_API="repos/$GITHUB_REPOSITORY"
LOGIN_PATTERN='^[A-Za-z0-9-]+$'

has_write() {
  local permission
  [[ "$1" =~ $LOGIN_PATTERN ]] || return 1
  # `permission` reports maintain as write.
  permission=$(gh api "$REPO_API/collaborators/$1/permission" --jq '.permission') || return 1
  [[ "$permission" == "admin" || "$permission" == "write" ]]
}

refuse() {
  gh api --silent "$REPO_API/issues/$PR_NUMBER/comments" -f body="$1"
  echo "::error::$1"
  exit 1
}

# 1. Command and commenter.
FIRST_LINE="${COMMENT%%$'\n'*}"
COMMAND_PATTERN='^@rcgitbot accept external[[:space:]]*$'
shopt -s nocasematch
if [[ ! "$FIRST_LINE" =~ $COMMAND_PATTERN ]]; then
  echo "::error::Expected '@rcgitbot accept external'."
  exit 1
fi
shopt -u nocasematch

if ! has_write "$LOGIN"; then
  echo "::error::$LOGIN does not have write permission."
  exit 1
fi

# 2. Pull request.
PR_JSON=$(gh api "$REPO_API/pulls/$PR_NUMBER")
STATE=$(jq -r '.state' <<<"$PR_JSON")
DRAFT=$(jq -r '.draft' <<<"$PR_JSON")
IS_FORK=$(jq -r '.head.repo.fork' <<<"$PR_JSON")
HEAD_SHA=$(jq -r '.head.sha' <<<"$PR_JSON")
BASE_REF=$(jq -r '.base.ref' <<<"$PR_JSON")
AUTHOR=$(jq -r '.user.login' <<<"$PR_JSON")
TITLE=$(jq -r '.title' <<<"$PR_JSON")
BODY=$(jq -r '.body // ""' <<<"$PR_JSON")
LABELS=$(jq -r '[.labels[].name | select(startswith("pr:"))] | join(",")' <<<"$PR_JSON")

[[ "$STATE" == "open" ]] || refuse "This PR is not open."
[[ "$DRAFT" == "false" ]] || refuse "This PR is a draft."
[[ "$IS_FORK" == "true" ]] || refuse "This PR is not from a fork."
[[ "$AUTHOR" =~ $LOGIN_PATTERN ]] || refuse "Unsupported author login."

# A base that is already this branch means an earlier run retargeted the PR.
BRANCH="external/$AUTHOR/$PR_NUMBER"
if [[ "$BASE_REF" != "$DEFAULT_BRANCH" && "$BASE_REF" != "$BRANCH" ]]; then
  refuse "This PR targets \`$BASE_REF\`. It has to target \`$DEFAULT_BRANCH\`."
fi

# 3. Approval: each reviewer's latest decision, on HEAD_SHA, from a maintainer.
APPROVERS=$(gh api --paginate "$REPO_API/pulls/$PR_NUMBER/reviews" \
  | jq -rs --arg sha "$HEAD_SHA" --arg author "$AUTHOR" '
      add
      | map(select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED"))
      | group_by(.user.login)
      | map(last)
      | .[]
      | select(.state == "APPROVED" and .commit_id == $sha and .user.login != $author)
      | .user.login')
APPROVED=false
while IFS= read -r approver; do
  if has_write "$approver"; then
    APPROVED=true
    break
  fi
done <<<"$APPROVERS"
if [[ "$APPROVED" != "true" ]]; then
  refuse "No approval from a maintainer on the latest commit (\`${HEAD_SHA:0:7}\`). Review it and approve again, then repeat the command."
fi

# 4. Branch and retarget.
ORIGINAL_TITLE="${TITLE#\[EXTERNAL\] }"
if [[ "$BASE_REF" != "$BRANCH" ]]; then
  DEFAULT_SHA=$(gh api "$REPO_API/git/ref/heads/$DEFAULT_BRANCH" --jq '.object.sha')
  gh api --silent "$REPO_API/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$DEFAULT_SHA" \
    || refuse "Could not create \`$BRANCH\`. Delete it if it is left over from an earlier attempt."
  gh api --silent -X PATCH "$REPO_API/pulls/$PR_NUMBER" \
    -f base="$BRANCH" -f title="[EXTERNAL] $ORIGINAL_TITLE" \
    || refuse "Could not retarget this PR to \`$BRANCH\`."
fi

# 5. Merge.
# GitHub recomputes mergeability asynchronously after a base change;
# `mergeable` is null until it is done.
for _ in 1 2 3 4 5 6; do
  PR_JSON=$(gh api "$REPO_API/pulls/$PR_NUMBER")
  [[ "$(jq -r '.mergeable' <<<"$PR_JSON")" != "null" ]] && break
  sleep 10
done

# A PR author can change the base branch of their own PR at any time, and the
# merge call cannot name a base.
if [[ "$(jq -r '.base.ref' <<<"$PR_JSON")" != "$BRANCH" ]]; then
  refuse "The base branch of this PR changed during the run. Repeat the command."
fi

if ! MERGE_ERROR=$(gh api --silent -X PUT "$REPO_API/pulls/$PR_NUMBER/merge" \
  -f merge_method=squash \
  -f sha="$HEAD_SHA" \
  -f commit_title="$ORIGINAL_TITLE (#$PR_NUMBER)" \
  -f commit_message="$BODY" 2>&1); then
  refuse "Could not merge into \`$BRANCH\` at \`${HEAD_SHA:0:7}\`: $MERGE_ERROR"
fi

# 6. Reply. A person opens the internal PR, so it gets a second reviewer.
LINK=$(jq -rn \
  --arg base "$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/compare/$DEFAULT_BRANCH...$BRANCH" \
  --arg title "[EXTERNAL] $ORIGINAL_TITLE (#$PR_NUMBER) via @$AUTHOR" \
  --arg body "External contribution from @$AUTHOR, merged into this branch to run CI. Original PR: #$PR_NUMBER" \
  --arg labels "$LABELS" \
  '"\($base)?quick_pull=1&title=\($title | @uri)&body=\($body | @uri)&labels=\($labels | @uri)"')
gh api --silent "$REPO_API/issues/$PR_NUMBER/comments" \
  -f body="Merged into \`$BRANCH\` at \`${HEAD_SHA:0:7}\`. [Open the internal PR]($LINK) against \`$DEFAULT_BRANCH\`."
