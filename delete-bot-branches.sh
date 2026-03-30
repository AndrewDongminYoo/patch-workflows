#!/usr/bin/env bash
# delete-bot-branches.sh
# chore/skip-bot-pr-workflows 원격 브랜치를 전체 리포에서 일괄 삭제합니다.

set -euo pipefail

BRANCH_NAME="chore/skip-bot-pr-workflows"
GH_USER=$(gh api user -q .login)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR]${NC}   $*"; }

info "대상 사용자: ${GH_USER}"
info "삭제할 브랜치: ${BRANCH_NAME}"
echo ""

REPOS=$(gh repo list "$GH_USER" --limit 200 --json name -q '.[].name')
DELETED=()
ERRORS=()

while read -r repo; do
  BRANCH=$(gh api "repos/${GH_USER}/${repo}/branches/${BRANCH_NAME}" \
    --jq '.name' 2>/dev/null || echo "")

  if [[ -z "$BRANCH" ]]; then
    continue
  fi

  if gh api --method DELETE "repos/${GH_USER}/${repo}/git/refs/heads/${BRANCH_NAME}" 2>/dev/null; then
    success "${repo}: 삭제 완료"
    DELETED+=("$repo")
  else
    error "${repo}: 삭제 실패"
    ERRORS+=("$repo")
  fi
done <<< "$REPOS"

echo ""
echo "════════════════════════════════════════"
success "삭제 완료: ${#DELETED[@]}개"
[[ ${#ERRORS[@]} -gt 0 ]] && error "실패: ${#ERRORS[@]}개 — ${ERRORS[*]}"
