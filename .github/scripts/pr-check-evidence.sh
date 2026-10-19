#!/usr/bin/env bash
# Find a successful pull-request check run that tested exactly the tree being published.
#
# Usage: pr-check-evidence.sh <pr-check-workflow-file> <commit-sha>
# Env:   GH_TOKEN (contents: read, pull-requests: read, actions: read), GITHUB_REPOSITORY.
# Out:   appends "run_id=<id>" (evidence found) or "run_id=" (none) to $GITHUB_OUTPUT,
#        and always exits 0.
#
# The PR check workflow names its run "... (merge <sha>)", where <sha> is the test
# merge commit it checked out (github.sha of a pull_request event). Evidence counts
# only when all of these hold:
#   - a merged pull request from this repository is associated with <commit-sha>;
#   - a pull_request run of <pr-check-workflow-file> from this repository, for that
#     pull request's head commit, not triggered by Dependabot, created within the last
#     7 days, completed with conclusion "success";
#   - the run's recorded test merge commit has the pull request head as its second
#     parent and exactly the same git tree as <commit-sha>; when <commit-sha> is a merge
#     commit, both also share the same first parent (the same base).
# The same tree includes the same workflow definition, so the run's checks are the
# ones this commit defines. Trust boundary: the merge sha is reported by ci.yml itself,
# so ci.yml and the publishers are release-gating files that must be reviewed like
# the publisher. Any lookup failure means "no evidence": the caller runs its suite.
set -uo pipefail
set -f

out="${GITHUB_OUTPUT:-/dev/stdout}"
hex='^[0-9a-f]{40}$'

none() {
  echo "No pull-request check evidence for ${commit:-?}: $*" >&2
  echo "run_id=" >> "$out"
  exit 0
}

workflow="${1:-}"
commit="${2:-}"
repo="${GITHUB_REPOSITORY:-}"
[[ -n "$repo" ]] || none "GITHUB_REPOSITORY is not set"
[[ "$commit" =~ $hex ]] || none "commit is not a full lowercase SHA"
[[ "$workflow" =~ ^[A-Za-z0-9._-]+\.ya?ml$ ]] || none "invalid workflow file name"

facts="$(gh api "repos/$repo/git/commits/$commit" \
  --jq '"\(.tree.sha) \(.parents | length) \(.parents[0].sha // "-")"')" || none "cannot read the commit"
read -r tree parent_count base <<< "$facts"
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
            and .repository.full_name == $repo and .head_repository.full_name == $repo
            and (.actor.login // "") != "dependabot[bot]"
            and (.triggering_actor.login // "") != "dependabot[bot]"
            and ((.created_at // "1970-01-01T00:00:00Z") | fromdateiso8601) > (now - 7 * 86400)))
        | sort_by(-.id) | .[]
        | "\(.id) \((.display_title // "") | capture("\\(merge (?<m>[0-9a-f]{40})\\)$").m // "-")"')" || continue
  while read -r run_id merge; do
    [[ "$run_id" =~ ^[0-9]+$ && "$merge" =~ $hex ]] || continue
    merge_facts="$(gh api "repos/$repo/git/commits/$merge" \
      --jq '"\(.tree.sha) \(.parents[0].sha // "-") \(.parents[1].sha // "-")"')" || continue
    read -r merge_tree merge_base merge_head <<< "$merge_facts"
    if [[ "$merge_head" != "$head" ]]; then
      echo "Run $run_id names merge $merge whose second parent is $merge_head, not head $head" >&2
    elif [[ "$merge_tree" != "$tree" ]]; then
      echo "Run $run_id tested merge $merge with tree $merge_tree, not $tree" >&2
    elif [[ "$parent_count" == 2 && "$merge_base" != "$base" ]]; then
      echo "Run $run_id tested merge $merge on base $merge_base, not $base" >&2
    else
      echo "Pull-request check run $run_id passed on merge $merge (head $head) with tree $tree" >&2
      echo "run_id=$run_id" >> "$out"
      exit 0
    fi
  done <<< "$runs"
done
none "no successful $workflow pull_request run tested tree $tree"
