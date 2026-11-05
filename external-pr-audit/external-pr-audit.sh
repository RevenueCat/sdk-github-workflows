#!/usr/bin/env bash
# Tripwire audit of a fork PR. Reads the PR's git objects as data and posts the
# hits to Slack. Never checks out, builds or runs anything from the PR, and
# prints nothing derived from it to the (public) job log.
set -euo pipefail

export LC_ALL=C
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0

work=$(mktemp -d "${RUNNER_TEMP:-/tmp}/external-pr-audit.XXXXXX")
hits="$work/hits"
: > "$hits"
: > "$work/dropped"
: > "$work/status"
expected_status() { local status=$?; (( status <= 1 || status == 141 )); }

hit() {
  local category=$1 text=${*:2}
  if [[ $category != status && -e $work/full.$category ]]; then printf '%s\t\n' "$category" >> "$work/dropped"; return; fi
  text=${text:0:200}
  text=${text//@/(at)}
  text=${text:0:200}
  text=${text//[^[:print:]]/?}
  text=${text//[&<>\`]/?}
  if [[ $category == status ]]; then printf '%s\n' "$text" >> "$work/status"; return; fi
  printf '%s\t%s\n' "$category" "$text" >> "$hits"
  (( $(grep -c "^$category"$'\t' "$hits") < 8 )) || : > "$work/full.$category"
}

posted=0
post() {
  local hit_count
  hit_count=$(cat "$hits" "$work/dropped" | grep -c '' || true)
  cat "$hits" "$work/dropped" | sort -s -t $'\t' -k1,1 | awk -F '\t' '
    $2 != "" { print $2; next }
    { more[$1]++ }
    END { for (c in more) printf "(+%d more %s hits)\n", more[c], c }
  ' > "$work/hits_text"
  jq -n --arg header "Tripwire audit of $REPOSITORY#$PR_NUMBER at ${HEAD_SHA:0:12} by $AUTHOR: $hit_count hits" \
    --rawfile hits "$work/hits_text" --rawfile status "$work/status" '{
    text: ((if $hits + $status == "" then $header else $header + "\n```\n" + $hits + $status + "```" end)
      | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;")),
    unfurl_links: false, unfurl_media: false
  }' > "$work/payload.json"
  curl --silent --fail --show-error --max-time 15 \
    -X POST -H 'Content-type: application/json' --data @"$work/payload.json" "$WEBHOOK_URL"
  posted=1
}

signalled=0
finished=0
on_exit() {
  if (( ! posted )); then
    if (( finished )); then
      hit status "the first post to Slack failed; this is a retry with the complete hits"
    elif (( signalled )); then
      hit status "AUDIT STOPPED: cancelled by a newer run or timed out; hits above are partial"
    else
      hit status "AUDIT FAILED before finishing: the job errored; hits above are partial, review by hand"
    fi
    post || true
  fi
  rm -rf "$work"
}
trap on_exit EXIT
trap 'signalled=1; exit 143' TERM INT

[[ $REPOSITORY =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "invalid REPOSITORY" >&2; exit 1; }
[[ $PR_NUMBER =~ ^[0-9]+$ ]] || { echo "invalid PR_NUMBER" >&2; exit 1; }
[[ $HEAD_SHA =~ ^[0-9a-f]{40}$ ]] || { echo "invalid HEAD_SHA" >&2; exit 1; }
[[ $AUTHOR =~ ^[A-Za-z0-9-]+(\[bot\])?$ ]] || { echo "invalid AUTHOR" >&2; exit 1; }
git check-ref-format --branch "$BASE_REF" > /dev/null || { echo "invalid BASE_REF" >&2; exit 1; }
git check-ref-format --branch "$DEFAULT_BRANCH" > /dev/null || { echo "invalid DEFAULT_BRANCH" >&2; exit 1; }
PR_TITLE=$(jq -r '.pull_request.title // ""' "$GITHUB_EVENT_PATH")
PR_BODY=$(jq -r '.pull_request.body // ""' "$GITHUB_EVENT_PATH")

git() { command git -c core.hooksPath=/dev/null -c attr.tree=4b825dc642cb6eb9a060e54bf8d69288fbee4904 -c core.attributesFile=/dev/null "$@"; }
fetch() {
  git -c protocol.allow=never -c protocol.https.allow=always \
    fetch -q --no-tags --no-recurse-submodules --filter=blob:limit=1m origin \
    "refs/heads/$BASE_REF:refs/audit/base" "refs/pull/$PR_NUMBER/head:refs/audit/head" "$@"
}

git init -q "$work/repo"
cd "$work/repo"
git remote add origin "${REMOTE_URL:-https://github.com/$REPOSITORY}"
fetch "$HEAD_SHA" 2> /dev/null || fetch

if ! git cat-file -e "$HEAD_SHA^{commit}" 2> /dev/null; then
  hit status "head $HEAD_SHA is no longer reachable (force-pushed away); the next run audits the new head"
  finished=1
  post
  exit 0
fi

if ! base=$(git merge-base refs/audit/base "$HEAD_SHA" 2> /dev/null); then
  hit status "no common ancestor with $BASE_REF (unrelated history)"
  finished=1
  post
  exit 0
fi
pr_diff() { git diff --no-ext-diff --no-textconv --no-renames --no-color "$base" "$HEAD_SHA" "$@"; }
pr_log() { git log "$@" "$base..$HEAD_SHA"; }

# 1. Base branch
[[ $BASE_REF == "$DEFAULT_BRANCH" ]] || hit base "base branch is '$BASE_REF', not '$DEFAULT_BRANCH'"

# 2. Paths that run on CI, on install, or steer agents
sensitive_paths='(^|/)(\.circleci|\.github|fastlane|scripts|tools?|bin|ci|buildSrc|build-logic|gradle|Tuist|Editor|\.husky|\.vscode|\.idea|\.claude|\.cursor|\.codex|\.gemini|\.yarn)/|(^|/)(Gemfile[^/]*|Dangerfile|Makefile|Rakefile|mise\.toml|Brewfile|\.pre-commit-config\.yaml|lefthook\.yml|\.rubocop\.yml|gradlew|gradlew\.bat|gradle\.properties|Package(@swift-[^/]*)?\.swift|Package\.resolved|Podfile[^/]*|project\.pbxproj|Project\.swift|Workspace\.swift|Tuist\.swift|package\.json|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb|\.npmrc|\.yarnrc[^/]*|\.pnpmfile\.cjs|pubspec\.yaml|pubspec\.lock|plugin\.xml|\.gitmodules|\.gitattributes|\.gitignore|AGENTS\.md|CLAUDE\.md|GEMINI\.md|\.cursorrules|\.windsurfrules|\.clinerules|copilot-instructions\.md|\.mcp\.json)$|\.(gradle|gradle\.kts|gemspec|podspec|podspec\.json|xcscheme|xcconfig|toml)$|(^|/)[^/]*\.config\.[cm]?[jt]s$|(^|/)\.eslintrc[^/]*$|(^|/)\.env[^/]*$'
pr_diff --name-only -z | while IFS= read -r -d '' path; do
  if [[ $path =~ $sensitive_paths ]]; then hit path "$path: runs on CI, on install, or steers agents"; fi
done || expected_status

# 3. Filesystem: symlinks, submodules, mode changes, deletions, binaries
pr_diff --raw -z | while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
  read -r old_mode new_mode _ _ status <<< "${meta#:}"
  case $new_mode in
    120000) hit symlink "$path: symlink" ;;
    160000) hit submodule "$path: submodule pointer" ;;
  esac
  if [[ $status == D ]]; then hit deleted "$path: deleted"; fi
  if [[ $old_mode != 000000 && $new_mode != 000000 && $old_mode != "$new_mode" ]]; then hit mode "$path: mode $old_mode to $new_mode"; fi
done || expected_status
pr_diff --numstat -z | while IFS= read -r -d '' entry; do
  if [[ $entry == $'-\t-\t'* ]]; then hit binary "${entry#*$'\t'*$'\t'}: binary"; fi
done || expected_status

# Added lines, as "path:line:content"
nonce=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
pr_diff -U0 --dst-prefix="$nonce/" | tr -d '\000' | head -c 50000001 > "$work/raw" || (( $(wc -c < "$work/raw") > 50000000 ))
if (( $(wc -c < "$work/raw") > 50000000 )); then hit status "diff over 50 MB, truncated: only the first part was checked"; fi
awk -v nonce="$nonce" '
  index($0, "+++ " nonce "/") == 1 { path = substr($0, 6 + length(nonce)); sub(/\t$/, "", path); gsub(/:/, "%3A", path); next }
  index($0, "+++ \"" nonce "/") == 1 { path = substr($0, 7 + length(nonce)); sub(/\t$/, "", path); sub(/"$/, "", path); gsub(/:/, "%3A", path); next }
  /^@@/ { header = 0; match($0, /\+[0-9]+/); line = substr($0, RSTART + 1, RLENGTH - 1); next }
  /^diff --git / { header = 1 }
  header && $0 == "+++ /dev/null" { next }
  /^\+/ { printf "%s:%d:%s\n", path, line, substr($0, 2); line++ }
' "$work/raw" | head -c 50000001 > "$work/added" || (( $(wc -c < "$work/added") > 50000000 ))
if (( $(wc -c < "$work/added") > 50000000 )); then hit status "added lines over 50 MB, truncated: only the first part was checked"; fi

# 4. Characters: bidi controls (U+202A-202E, U+2066-2069), zero-width (U+200B-200D), BOM (U+FEFF), as UTF-8 bytes
perl -ne 'print if /\xE2\x80[\xAA-\xAE]|\xE2\x81[\xA6-\xA9]|\xE2\x80[\x8B-\x8D]|\xEF\xBB\xBF/' "$work/added" 2> /dev/null \
  | head -n 200 | cut -d: -f1,2 | while IFS= read -r location; do hit bidi "$location: bidi or invisible character"; done || expected_status
grep -viE '^[^:]*\.(md|markdown|txt|rst|strings|stringsdict|xcstrings|arb|po|pot|json|csv|html):' "$work/added" \
  | sed $'s/\r$//' | grep $'[^ -~\t]' | head -n 200 | cut -d: -f1,2 | while IFS= read -r location; do hit non-ascii "$location: non-ASCII in code"; done || expected_status

# 5. Agent-directed instructions
injection='ignore (all |the |any )?(previous|prior|above) instructions|as an ai|you are an? (ai|assistant|agent|llm)|skip the audit|approve (this|the) (pr|pull request)|merge this|@claude|gh pr (merge|review|edit)|claude\.md|agents\.md'
printf '%s\n' "$PR_TITLE" | grep -iEo "$injection" | sort -u | while IFS= read -r phrase; do hit title-phrase "title: \"$phrase\""; done || expected_status
printf '%s\n' "$PR_BODY" | grep -iEo "$injection" | sort -u | while IFS= read -r phrase; do hit body-phrase "body: \"$phrase\""; done || expected_status
pr_log --format=%B | grep -iEo "$injection" | sort -u | while IFS= read -r phrase; do hit message-phrase "commit message: \"$phrase\""; done || expected_status
grep -iE "^[^:]*:[0-9]+:.*($injection)" "$work/added" | head -n 200 | cut -d: -f1,2 | while IFS= read -r location; do hit code-phrase "$location: agent-directed phrase"; done || expected_status

# 6. New hosts and remote images
url_pattern='(https?:|[("'"'"'`])//[^][:space:]/?#"'"'"'` <>),;*]+'
{ git grep -ohiI -E "$url_pattern" "$base" 2> /dev/null || true; } | sed -E 's|^.*//||; s|[.:]$||' | tr '[:upper:]' '[:lower:]' | sort -u > "$work/known_hosts"
grep -oiE "$url_pattern" "$work/added" | sed -E 's|^.*//||; s|[.:]$||' | tr '[:upper:]' '[:lower:]' | sort -u \
  | comm -23 - "$work/known_hosts" | head -n 50 | while IFS= read -r host; do hit host "new host: $host"; done || expected_status
grep -iE '^[^:]*\.(md|markdown):[0-9]+:.*(!\[[^]]*\]\([^)]*//|<img[^>]*src=["'"'"']?[^"'"'"' >]*//)' "$work/added" | head -n 200 | cut -d: -f1,2 | while IFS= read -r location; do hit image "$location: remote image or badge"; done || expected_status

# 7. Commits
pr_log --merges --format=%h | while IFS= read -r sha; do hit merge "commit $sha: merge commit"; done || expected_status
pr_log --format=%ae | tr '[:upper:]' '[:lower:]' | sort -u > "$work/emails"
email_count=$(grep -c '' "$work/emails" || true)
(( email_count > 1 )) && hit emails "commits by $email_count author emails"
author_lower=$(printf '%s' "$AUTHOR" | tr '[:upper:]' '[:lower:]')
grep -E '@revenuecat\.com$|@users\.noreply\.github\.com$' "$work/emails" | while IFS= read -r email; do
  [[ $email =~ ^([0-9]+\+)?"$author_lower"@users\.noreply\.github\.com$ ]] || hit identity "author email $email claims an identity other than $AUTHOR"
done || expected_status
pr_log --format=%B | grep -iE '^co-authored-by:' | sort -u | while IFS= read -r trailer; do hit trailer "commit trailer: $trailer"; done || expected_status

finished=1
post
