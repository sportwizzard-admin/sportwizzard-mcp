#!/usr/bin/env bash
# Find a successful pull-request check run that tested exactly the tree being published.
#
# Usage: pr-check-evidence.sh <pr-check-workflow-file> <commit-sha>
# Env:   GH_TOKEN (contents: read, pull-requests: read, actions: read), GITHUB_REPOSITORY.
# Out:   appends "run_id=<id>" (evidence found) or "run_id=" (none) to $GITHUB_OUTPUT.
#
# The PR check workflow names its run "... (merge <sha>)", where <sha> is the test
# merge commit it checked out (github.sha of a pull_request event). Evidence counts
# only when all of these hold:
#   - a merged pull request from this repository is associated with <commit-sha>;
#   - a pull_request run of <pr-check-workflow-file> from this repository, for that
#     pull request's head commit, completed with conclusion "success";
#   - the run's recorded test merge commit has the pull request head as its second
#     parent and exactly the same git tree as <commit-sha>.
# The same tree includes the same workflow definition, so the run's checks are the
# ones this commit defines. Any lookup failure means "no evidence": the caller then
# runs its own suite.
set -uo pipefail

workflow="${1:?workflow file}"
commit="${2:?commit sha}"
repo="${GITHUB_REPOSITORY:?}"
out="${GITHUB_OUTPUT:-/dev/stdout}"
hex='^[0-9a-f]{40}$'

none() {
  echo "No pull-request check evidence for $commit: $*" >&2
  echo "run_id=" >> "$out"
  exit 0
}

[[ "$commit" =~ $hex ]] || none "commit is not a full lowercase SHA"
[[ "$workflow" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] || none "invalid workflow file name"
tree="$(gh api "repos/$repo/git/commits/$commit" --jq .tree.sha)" || none "cannot read the commit tree"
[[ "$tree" =~ $hex ]] || none "commit tree is not a SHA"

heads="$(gh api "repos/$repo/commits/$commit/pulls" \
  | jq -r --arg repo "$repo" \
    '.[] | select(.merged_at != null and .base.repo.full_name == $repo and .head.repo.full_name == $repo) | .head.sha')" \
  || none "cannot list pull requests for the commit"
[[ -n "$heads" ]] || none "no merged same-repository pull request is associated with it"

for head in $heads; do
  [[ "$head" =~ $hex ]] || continue
  runs="$(gh api "repos/$repo/actions/workflows/$workflow/runs?event=pull_request&head_sha=$head&status=success&per_page=100" \
    | jq -r --arg repo "$repo" --arg head "$head" --arg path ".github/workflows/$workflow" \
      '.workflow_runs
        | map(select(.event == "pull_request" and .status == "completed" and .conclusion == "success"
            and .head_sha == $head and .path == $path
            and .repository.full_name == $repo and .head_repository.full_name == $repo))
        | sort_by(-.id) | .[]
        | "\(.id) \(.display_title | capture("\\(merge (?<m>[0-9a-f]{40})\\)$").m // "-")"')" || continue
  while read -r run_id merge; do
    [[ "$run_id" =~ ^[0-9]+$ && "$merge" =~ $hex ]] || continue
    facts="$(gh api "repos/$repo/git/commits/$merge" --jq '"\(.tree.sha) \(.parents[1].sha // "-")"')" || continue
    read -r merge_tree merge_head <<< "$facts"
    if [[ "$merge_head" == "$head" && "$merge_tree" == "$tree" ]]; then
      echo "Pull-request check run $run_id passed on merge $merge (head $head) with tree $tree" >&2
      echo "run_id=$run_id" >> "$out"
      exit 0
    fi
    echo "Run $run_id tested merge $merge with tree $merge_tree, not $tree" >&2
  done <<< "$runs"
done
none "no successful $workflow pull_request run tested tree $tree"
