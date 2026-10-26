#!/usr/bin/env bash
# `@rcgitbot merge-external [pr:label ...]` on a fork PR. The comment, the PR title and the
# changed paths are attacker-controlled; every value arrives through the environment.
set -euo pipefail

RUN_URL="$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"

react() {
  gh api "repos/$REPO/issues/comments/$COMMENT_ID/reactions" -f content="$1" --silent || true
}

comment() {
  gh api "repos/$REPO/issues/$PR_NUMBER/comments" -f body="$1" --silent
}

refuse() {
  echo "::error::$1"
  comment "Not merged: $1. [Run log]($RUN_URL)" || true
  react -1
  exit 1
}

# The legacy `permission` field folds maintain into write and triage into read.
has_write_access() {
  local permission
  permission=$(gh api "repos/$REPO/collaborators/$1/permission" --jq .permission) \
    || { echo "::error::Could not read the permission of $1 on $REPO; check the token."; exit 1; }
  [[ "$permission" == "admin" || "$permission" == "write" ]]
}

# 1. Commenter.
if ! has_write_access "$COMMENTER"; then
  echo "$COMMENTER has no write access to $REPO, ignoring."
  exit 0
fi

# 2. Command. Bash's `^`/`$` anchor the whole string, so any second line fails the match.
COMMAND=$(printf '%s' "$COMMENT_BODY" | tr -d '\r' | tr '[:upper:]' '[:lower:]')
COMMAND_PATTERN='^@rcgitbot merge-external(( +pr:[a-z]+)*) *$'
if [[ ! "$COMMAND" =~ $COMMAND_PATTERN ]]; then
  refuse "unrecognized command, expected \`@rcgitbot merge-external [pr:label ...]\`"
fi
read -r -a LABELS <<< "${BASH_REMATCH[1]}"

# 3. PR state, pinned to the head SHA seen now.
PR_JSON=$(gh pr view "$PR_NUMBER" -R "$REPO" \
  --json state,isCrossRepository,baseRefName,headRefOid,reviewDecision,author,title,labels,changedFiles)
SHA=$(jq -r .headRefOid <<< "$PR_JSON")
AUTHOR=$(jq -r .author.login <<< "$PR_JSON")
ORIGINAL_TITLE=$(jq -r .title <<< "$PR_JSON")
TITLE=${ORIGINAL_TITLE#"[EXTERNAL] "}

[[ "$(jq -r .state <<< "$PR_JSON")" == "OPEN" ]] || refuse "the PR is not open"
[[ "$(jq -r .isCrossRepository <<< "$PR_JSON")" == "true" ]] || refuse "the PR is not from a fork"
[[ "$(jq -r .baseRefName <<< "$PR_JSON")" == "$DEFAULT_BRANCH" ]] || refuse "the PR does not target \`$DEFAULT_BRANCH\`"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || refuse "unexpected head SHA"
[[ "$AUTHOR" =~ ^[A-Za-z0-9-]+$ ]] || refuse "unexpected author login"
[[ "$(jq -r .reviewDecision <<< "$PR_JSON")" == "APPROVED" ]] || refuse "the PR is not approved"

# 4. An approval from someone with write access on exactly this commit, so a
# push after the review cannot ride along.
APPROVERS=$(gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/reviews?per_page=100" \
  --jq ".[] | select(.state == \"APPROVED\" and .commit_id == \"$SHA\") | .user.login" | sort -u)
approved_at_head() {
  for approver in $APPROVERS; do
    has_write_access "$approver" && return 0
  done
  return 1
}
approved_at_head || refuse "no approval on the current head commit; review the latest push and approve again"

# 5. Paths that run in CI, binaries, submodule bumps and agent configuration go through
# the manual process. The PR files API lists at most 3000 files.
(( $(jq -r .changedFiles <<< "$PR_JSON") < 3000 )) || refuse "too many changed files to check"
SENSITIVE_PATH_PATTERN=$(paste -sd '|' <<'EOF'
(^|/)\.
(^|/)(fastlane|scripts|bin|tools|tool|hook|buildSrc|build-logic|gradle|Tuist)/
(^|/)(Gemfile|Dangerfile|Podfile|Cartfile|Brewfile|Makefile|Rakefile|Fastfile|gradlew)[^/]*$
(^|/)(Package(@[^/]*)?\.swift|Package\.resolved|Project\.swift|Workspace\.swift|Tuist\.swift)$
(^|/)(package\.json|pubspec\.yaml|mise\.toml|gradle\.properties|CMakeLists\.txt|pyproject\.toml|setup\.cfg)$
(^|/)(AGENTS\.md|CLAUDE\.md|Directory\.Build\.[^/]*|app\.plugin\.[cm]?js|jest\.setup\.[^/]*|karma\.conf\.[^/]*)$
(^|/)(Dockerfile[^/]*|(docker-)?compose\.ya?ml|lefthook[^/]*\.ya?ml)$
\.(gradle|kts|podspec|gemspec|rake|sh|bash|zsh|rb|py|ps1|bat|cmd|groovy|cmake|mk)$
\.(pbxproj|xcscheme|xcconfig|xctestplan|csproj|props|targets|lock|lockb)$
\.(dll|so|dylib|a|jar|aar|class|dex|exe|wasm|node|bin)$
\.(zip|apk|aab|ipa|unitypackage|tar|tgz|gz|xz|7z)$
\.(xcframework|framework|bundle)/
-lock\.(json|yaml)$
\.config\.[cm]?[jt]s$
EOF
)
SENSITIVE_PATHS=$(gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/files?per_page=100" \
  | jq -r --arg pattern "$SENSITIVE_PATH_PATTERN" \
    '.[] | select(
        ([.filename, .previous_filename // empty] | any(test($pattern; "i") or test("[[:cntrl:]]")))
        or ((.patch // "") | test("Subproject commit"))
      ) | .filename | @json')
if [[ -n "$SENSITIVE_PATHS" ]]; then
  echo "Sensitive paths:"
  echo "$SENSITIVE_PATHS"
  refuse "the PR changes CI, build, binary, submodule or agent configuration files (listed in the run log), so it needs the manual process"
fi
CURRENT_SHA=$(gh pr view "$PR_NUMBER" -R "$REPO" --json headRefOid --jq .headRefOid)
[[ "$CURRENT_SHA" == "$SHA" ]] || refuse "the PR changed while it was being checked; review the latest push and approve again"

# 6. Labels. Adding a label that does not exist to an issue creates it.
if (( ${#LABELS[@]} > 0 )); then
  for label in "${LABELS[@]}"; do
    gh api "repos/$REPO/labels/$label" --silent || refuse "label \`$label\` does not exist in this repo"
  done
else
  mapfile -t LABELS < <(jq -r '.labels[].name | select(startswith("pr:"))' <<< "$PR_JSON")
fi

# 7. Intermediate branch. Creating a ref that exists fails, so nothing is overwritten
# and a second run for the same PR stops here.
BRANCH="external/$AUTHOR/$PR_NUMBER"
BASE_SHA=$(gh api "repos/$REPO/git/ref/heads/$DEFAULT_BRANCH" --jq .object.sha)
gh api "repos/$REPO/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$BASE_SHA" --silent \
  || refuse "could not create \`$BRANCH\`, it may already exist"

# Until the merge lands, any exit (refusal, error, cancellation) undoes the retarget and
# the branch. Deleting the branch while the PR still targets it would close the PR.
MERGE_SHA=""
RETARGETED=false
undo() {
  [[ -z "$MERGE_SHA" ]] || return 0
  if [[ "$RETARGETED" == "true" ]]; then
    gh api -X PATCH "repos/$REPO/pulls/$PR_NUMBER" -f base="$DEFAULT_BRANCH" -f title="$ORIGINAL_TITLE" --silent || return 0
  fi
  gh api -X DELETE "repos/$REPO/git/refs/heads/$BRANCH" --silent || true
}
trap undo EXIT
trap 'exit 1' INT TERM

# 8. Retarget and squash-merge. `sha` pins the head, but the merge endpoint takes the
# base from the PR, which its author can change, so the base is checked around it.
gh api -X PATCH "repos/$REPO/pulls/$PR_NUMBER" -f base="$BRANCH" -f title="[EXTERNAL] $TITLE" --silent \
  || refuse "could not retarget the PR to \`$BRANCH\`"
RETARGETED=true
current_base() {
  gh api "repos/$REPO/pulls/$PR_NUMBER" --jq .base.ref
}

# GitHub answers 405 "Base branch was modified" for a few seconds after a retarget.
MERGE_ERROR=$(mktemp)
for attempt in 1 2 3 4; do
  [[ "$(current_base)" == "$BRANCH" ]] || refuse "the PR's base changed before the merge; the PR was retargeted back"
  MERGE_SHA=$(gh api -X PUT "repos/$REPO/pulls/$PR_NUMBER/merge" \
    -f merge_method=squash -f sha="$SHA" \
    -f commit_title="$TITLE (#$PR_NUMBER)" -f commit_message="Original PR: #$PR_NUMBER" \
    --jq .sha 2>"$MERGE_ERROR") && break
  MERGE_SHA=""
  cat "$MERGE_ERROR"
  if (( attempt == 4 )) || ! grep -q "Base branch was modified" "$MERGE_ERROR"; then
    break
  fi
  echo "Retrying in 5s..."
  sleep 5
done
# A lost response (e.g. a 5xx after the merge went through) must not trigger the undo.
if [[ -z "$MERGE_SHA" ]]; then
  MERGE_SHA=$(gh pr view "$PR_NUMBER" -R "$REPO" --json state,mergeCommit \
    --jq 'select(.state == "MERGED") | .mergeCommit.oid') || MERGE_SHA=""
fi
[[ -n "$MERGE_SHA" ]] || refuse "the squash merge into \`$BRANCH\` failed (conflicts, or a push since the approval); the PR was retargeted back"
[[ "$(current_base)" == "$BRANCH" ]] \
  || refuse "the PR's base changed during the merge, so the approved commit may have landed on another branch; check the PR's base branch before anything else"

# 9. Internal PR.
INTERNAL_PR=$(gh api "repos/$REPO/pulls" \
  -f base="$DEFAULT_BRANCH" -f head="$BRANCH" \
  -f title="[EXTERNAL] $TITLE (#$PR_NUMBER) via @$AUTHOR" \
  -f body="External contribution from @$AUTHOR, merged into this branch to run CI. Original PR: #$PR_NUMBER. Requested by @$COMMENTER." \
  --jq .number) \
  || refuse "merged into \`$BRANCH\`, but opening the internal PR failed; open it by hand"

gh api "repos/$REPO/issues/$INTERNAL_PR/assignees" -f "assignees[]=$COMMENTER" --silent \
  || echo "::warning::Could not assign $COMMENTER to #$INTERNAL_PR"
if (( ${#LABELS[@]} > 0 )); then
  LABEL_ARGS=()
  for label in "${LABELS[@]}"; do
    LABEL_ARGS+=(-f "labels[]=$label")
  done
  gh api "repos/$REPO/issues/$INTERNAL_PR/labels" "${LABEL_ARGS[@]}" --silent \
    || echo "::warning::Could not label #$INTERNAL_PR"
fi

comment "Merged into \`$BRANCH\` to run CI: #$INTERNAL_PR."
react +1
