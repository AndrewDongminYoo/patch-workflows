#!/usr/bin/env bash
# delete-bot-branches.sh
# Bulk delete remote chore/skip-bot-pr-workflows branches from the entire repository.

set -euo pipefail
export GH_PAGER=""

BRANCH_NAME="chore/skip-bot-pr-workflows"
GH_USER=$(gh api user -q .login)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERR]${NC}   $*"; }

info "Target user: ${GH_USER}"
info "Branches to delete: ${BRANCH_NAME}"
echo ""

REPOS=$(gh repo list "${GH_USER}" --limit 200 --json name -q '.[].name')
DELETED=()
ERRORS=()

while read -r repo; do
	BRANCH=$(gh api "repos/${GH_USER}/${repo}/branches/${BRANCH_NAME}" \
		--jq '.name' 2>/dev/null || echo "")

	if [[ -z ${BRANCH} ]]; then
		continue
	fi

	if GH_PAGER="" gh api --method DELETE "repos/${GH_USER}/${repo}/git/refs/heads/${BRANCH_NAME}" 2>/dev/null; then
		success "${repo}: Deletion complete"
		DELETED+=("${repo}")
	else
		error "${repo}: Deletion failed"
		ERRORS+=("${repo}")
	fi
done <<<"${REPOS}"

echo ""
echo "════════════════════════════════════════"
success "Deletion complete: ${#DELETED[@]} branches"
[[ ${#ERRORS[@]} -gt 0 ]] && error "Failed: ${#ERRORS[@]} errors — ${ERRORS[*]}"
