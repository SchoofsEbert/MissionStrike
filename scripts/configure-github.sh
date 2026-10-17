#!/usr/bin/env bash
# Applies the repository settings the release workflow relies on. Safe to re-run: each
# setting is created or updated in place. Needs `gh` logged in as a repository admin.
#
#   scripts/configure-github.sh [owner/repo]
#
# Secrets are not handled here; GitHub never returns their values, so they are set with
# `gh secret set` (see RELEASING.md).
set -euo pipefail

REPO="${1:-SchoofsEbert/MissionStrike}"
RULESET_NAME="Release tags"

# Deployments from `v*` tags only, so no branch can run a job in these environments.
configure_environment() {
    local env="$1"
    gh api --method PUT "repos/$REPO/environments/$env" --silent --input - <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
    local existing
    existing=$(gh api "repos/$REPO/environments/$env/deployment-branch-policies" \
        --jq '.branch_policies[] | select(.type == "tag" and .name == "v*") | .id')
    if [ -z "$existing" ]; then
        gh api --method POST "repos/$REPO/environments/$env/deployment-branch-policies" \
            -f name='v*' -f type=tag --silent
    fi
    echo "Environment $env: deployments from v* tags only."
}

# Only admins may create `v*` tags; nobody may move or delete one. A tag runs the release
# workflow from its own commit, so creating one is what can reach the signing step.
configure_tag_ruleset() {
    local body id
    body=$(cat <<JSON
{
  "name": "$RULESET_NAME",
  "target": "tag",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
  "rules": [{"type": "creation"}, {"type": "update"}, {"type": "deletion"}, {"type": "non_fast_forward"}],
  "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}]
}
JSON
)
    id=$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name == \"$RULESET_NAME\") | .id")
    if [ -n "$id" ]; then
        gh api --method PUT "repos/$REPO/rulesets/$id" --input - --silent <<<"$body"
    else
        gh api --method POST "repos/$REPO/rulesets" --input - --silent <<<"$body"
    fi
    echo "Ruleset \"$RULESET_NAME\": only admins create v* tags; none can be moved or deleted."
}

configure_environment release
configure_environment homebrew-tap
configure_tag_ruleset
