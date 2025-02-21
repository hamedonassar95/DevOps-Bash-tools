#!/usr/bin/env bash
#  vim:ts=4:sts=4:sw=4:et
#
#  Author: Hari Sekhon
#  Date: 2022-02-17 11:32:45 +0000 (Thu, 17 Feb 2022)
#
#  https://github.com/HariSekhon/DevOps-Bash-tools
#
#  License: see accompanying Hari Sekhon LICENSE file
#
#  If you're using my code you're welcome to connect with me on LinkedIn and optionally send me feedback to help steer this or other code I publish
#
#  https://www.linkedin.com/in/HariSekhon
#

set -euo pipefail
[ -n "${DEBUG:-}" ] && set -x
srcdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1090
. "$srcdir/lib/github.sh"

# shellcheck disable=SC2034,SC2154
usage_description="
Creates a GitHub Pull Request idempotently by first checking for an existing PR between the branches,
and also checking if there are the necessary commits between the branches, to avoid common errors from blindly raising PRs

Useful to automate audited code promotion across environments (eg. Staging branch -> Production branch)

Also works across repo forks if the head branch contains an '<owner>:' prefix

Useful Git terminology reminder:

The HEAD branch is the branch you want to merge FROM, eg. 'my-feature-branch'
The BASE branch is the branch you want to merge INTO, eg. 'master' or 'main'

Requires GitHub CLI to be installed and configured

Used by adjacent scripts:

    github_merge_branch.sh
    github_repo_fork_update.sh
"

# used by usage() in lib/utils.sh
# shellcheck disable=SC2034
usage_args="[<owner>/<repo> <from_head_branch> <to_base_branch>]"

help_usage "$@"

#min_args 2 "$@"
max_args 3 "$@"

owner_repo=""
if [ $# -eq 3 ]; then
    owner_repo="$1"
    shift || :
fi

head="${1:-}"
base="${2:-}"

if is_blank "$owner_repo"; then
    if ! is_in_git_repo; then
        die "Repo not specified and not in a git repository checkout to infer it"
    fi
    owner_repo='{owner}/{repo}'
fi

repo_data="$(gh api "/repos/$owner_repo")"

owner="$(jq -r '.owner.login' <<< "$repo_data")"
repo="$(jq -r '.name' <<< "$repo_data")"

if is_blank "$base"; then
    timestamp "Base branch not specified, inferring to be default branch from repo"
    base="$(jq -r '.default_branch' <<< "$repo_data")"
    timestamp "Using default branch '$base' as base branch"
fi

if is_blank "$head"; then
    if ! is_in_git_repo; then
        die "Head branch not specified and not in a git repository checkout to infer it"
    fi
    checkout_owner_repo="$(gh api '/repos/{owner}/{repo}' | jq -r '.full_name')"
    if [ "$owner/$repo" != "$checkout_owner_repo" ]; then
        die "ERROR: Head branch not specified and current git repository checkout we are within ($checkout_owner_repo) does not match the target repo ($owner/$repo), so cannot use local branch name to infer it"
    fi
    timestamp "Head branch not specified, inferring to be current branch from repo checkout"
    head="$(git rev-parse --abbrev-ref HEAD)"
    timestamp "Head branch was inferred from local git checkout branch to be '$head'"
    if [ "$head" = "$base" ]; then
        die "Cannot create pull request from head branch '$head' to base branch '$base' because they are the same branch! "
    fi
fi

if [[ "$head" =~ : ]]; then
    head_owner="${head%%:*}"
    head_name="${head##*:}"
else
    head_owner="$owner"
    head_name="$head"
fi

total_commits="$(gh api "/repos/$owner/$repo/compare/$base...$head" -q '.total_commits')"
if [ "$total_commits" -gt 0 ]; then
    # check for existing PR between these branches before creating another
    existing_pr="$(gh pr list -R "$owner/$repo" \
        --json baseRefName,changedFiles,commits,headRefName,headRepository,headRepositoryOwner,isCrossRepository,number,state,title,url \
        -q ".[] |
            select(.baseRefName == \"$base\") |
            select(.headRefName == \"$head_name\") |
            select(.headRepositoryOwner.login == \"$head_owner\")
    ")"
    existing_pr_url="$(jq -r '.url' <<< "$existing_pr")"
    if [ -n "$existing_pr" ]; then
        timestamp "Branch '$base' already has an existing pull request from '$head', skipping PR: $existing_pr_url"
        echo >&2
        exit 0
    fi
    timestamp "Creating Pull Request from head '$head' into base branch '$base'"
    # --no-maintainer-edit is important, otherwise member ci account gets error (and yes there is a double 'Fork collab' error in GitHub CLI's error message):
    # pull request create failed: GraphQL: Fork collab Fork collab can't be granted by someone without permission (createPullRequest)
    gh pr create -R "$owner/$repo" \
                 --base "$base" \
                 --head "$head" \
                 --title "Merge $head branch into $base branch" \
                 --body "Created automatically by script \`${0##*/}\` in the [DevOps Bash tools](https://github.com/HariSekhon/DevOps-Bash-tools) repo." \
                 --no-maintainer-edit
    echo >&2
else
    timestamp "Branch '$base' is already up to date with upstream, skipping PR"
    echo >&2
fi
