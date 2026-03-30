#!/usr/bin/env bash
# patch-workflows-skip-bots.sh
#
# 개인 GitHub 리포지토리의 모든 워크플로우에
# bot PR 트리거 스킵 조건을 일괄 추가합니다.
#
# 사전 요구사항:
#   - gh CLI (https://cli.github.com) 로그인 상태
#   - git, python3
#
# 사용법:
#   chmod +x patch-workflows-skip-bots.sh
#   ./patch-workflows-skip-bots.sh            # dry-run (기본값)
#   ./patch-workflows-skip-bots.sh --apply    # 실제 PR 생성

set -euo pipefail

# ── 설정 ────────────────────────────────────────────────────────────────────
BOT_ACTORS='["dependabot[bot]", "renovate[bot]", "snyk-bot", "allcontributors[bot]"]'
BRANCH_NAME="chore/skip-bot-pr-workflows"
COMMIT_MSG="ci: skip workflow runs on bot PRs"
PR_TITLE="ci: skip workflow runs on bot PRs"
PR_BODY="Adds \`if\` condition to all jobs to skip execution when triggered by dependency bots (dependabot, renovate, etc.), reducing unnecessary Actions minutes usage."

DRY_RUN=true
if [[ "${1:-}" == "--apply" ]]; then
  DRY_RUN=false
fi

# ── 색상 출력 ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR]${NC}   $*"; }

# ── 의존성 체크 ──────────────────────────────────────────────────────────────
for cmd in gh git python3; do
  if ! command -v "$cmd" &>/dev/null; then
    error "$cmd 가 설치되어 있지 않습니다."
    exit 1
  fi
done

GH_USER=$(gh api user -q .login)
info "GitHub 사용자: ${GH_USER}"
[[ "$DRY_RUN" == "true" ]] && warn "DRY-RUN 모드 — 실제 변경 없음. --apply 플래그로 적용"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

SUMMARY_PATCHED=()
SUMMARY_SKIPPED=()
SUMMARY_ERRORS=()

# ── Python 패치 함수 (인라인) ────────────────────────────────────────────────
# jobs 블록 아래 각 job에 if 조건을 추가합니다.
# 이미 조건이 있는 job은 건드리지 않습니다.
PATCHER_SCRIPT=$(cat <<'PYEOF'
import sys, re

BOT_CONDITION = "!contains(fromJSON('$BOT_ACTORS'), github.actor)"

def patch_workflow(content, bot_actors):
    condition = f"!contains(fromJSON('{bot_actors}'), github.actor)"
    
    # 이미 패치된 경우 스킵
    if "fromJSON" in content and "github.actor" in content:
        return None, "already_patched"
    
    lines = content.splitlines(keepends=True)
    result = []
    i = 0
    patched = False
    
    # jobs: 섹션 탐색
    in_jobs = False
    job_indent = None
    
    while i < len(lines):
        line = lines[i]
        stripped = line.rstrip()
        
        # jobs: 블록 시작 감지
        if re.match(r'^jobs\s*:', stripped):
            in_jobs = True
            result.append(line)
            i += 1
            continue
        
        if in_jobs:
            # job 이름 라인 감지: 2칸 또는 4칸 들여쓰기 + 식별자 + ":"
            m = re.match(r'^( {2,4})([a-zA-Z_][a-zA-Z0-9_-]*)(\s*:\s*)$', stripped + "")
            if m:
                indent = len(m.group(1))
                if job_indent is None:
                    job_indent = indent
                
                if len(line) - len(line.lstrip()) == job_indent:
                    result.append(line)
                    i += 1
                    
                    # 이 job 블록 내에 if: 가 있는지 미리 탐색
                    peek = i
                    has_if = False
                    has_uses = False  # reusable workflow는 if를 job 레벨에 둬야 함
                    while peek < len(lines):
                        pl = lines[peek].rstrip()
                        # 다음 job이 시작되면 중단
                        if re.match(r'^ {' + str(job_indent) + r'}[a-zA-Z_]', pl):
                            break
                        if re.match(r'^ {' + str(job_indent + 2) + r'}if\s*:', pl):
                            has_if = True
                            break
                        peek += 1
                    
                    if not has_if:
                        # if: 조건 삽입 (job 이름 다음 라인)
                        if_line = " " * (job_indent + 2) + f"if: ${{{{ {condition} }}}}\n"
                        result.append(if_line)
                        patched = True
                    continue
        
        result.append(line)
        i += 1
    
    if not patched:
        return None, "no_jobs_found"
    
    return "".join(result), "patched"


if __name__ == "__main__":
    filepath = sys.argv[1]
    bot_actors = sys.argv[2]
    
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()
    
    new_content, status = patch_workflow(content, bot_actors)
    
    if status == "already_patched":
        print("SKIP:already_patched")
        sys.exit(0)
    elif status == "no_jobs_found":
        print("SKIP:no_jobs_found")
        sys.exit(0)
    else:
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(new_content)
        print("OK:patched")
        sys.exit(0)
PYEOF
)

# ── 리포 목록 수집 ───────────────────────────────────────────────────────────
info "리포지토리 목록 가져오는 중..."
REPOS=$(gh repo list "$GH_USER" \
  --limit 200 \
  --no-archived \
  --json name,defaultBranchRef \
  --jq '.[] | "\(.name)|\(.defaultBranchRef.name // "main")"')

REPO_COUNT=$(echo "$REPOS" | wc -l | tr -d ' ')
info "총 ${REPO_COUNT}개 리포지토리 발견"
echo ""

# ── 리포별 처리 ──────────────────────────────────────────────────────────────
while IFS='|' read -r REPO_NAME DEFAULT_BRANCH; do
  FULL_REPO="${GH_USER}/${REPO_NAME}"
  REPO_DIR="${WORK_DIR}/${REPO_NAME}"
  
  info "처리 중: ${FULL_REPO} (기본 브랜치: ${DEFAULT_BRANCH})"
  
  # 워크플로우 파일 존재 여부 확인 (clone 전 API로 체크)
  # gh api 404 시 exit code 1을 반환하지 않고 JSON을 stdout에 출력하는 케이스 대응:
  # --jq 'length' 를 쓰면 404 JSON { "message": "Not Found", ... } → length=3 이 되어버리므로
  # HTTP status를 먼저 확인하고, 성공(200)일 때만 파일 수를 추출한다.
  WORKFLOW_API_RESPONSE=$(gh api "repos/${FULL_REPO}/contents/.github/workflows" \
    --include 2>/dev/null || true)
  
  HTTP_STATUS=$(echo "$WORKFLOW_API_RESPONSE" | grep -m1 '^HTTP/' | awk '{print $2}' || echo "0")
  
  if [[ "$HTTP_STATUS" != "200" ]]; then
    warn "  └ .github/workflows 없음, 스킵"
    SUMMARY_SKIPPED+=("$REPO_NAME (no workflows)")
    continue
  fi
  
  WORKFLOW_COUNT=$(echo "$WORKFLOW_API_RESPONSE" | tail -1 | python3 -c \
    "import sys,json; data=json.load(sys.stdin); print(len([f for f in data if f['name'].endswith(('.yml','.yaml'))]))" \
    2>/dev/null || echo "0")
  
  if [[ "$WORKFLOW_COUNT" == "0" ]]; then
    warn "  └ .github/workflows 있으나 yml/yaml 파일 없음, 스킵"
    SUMMARY_SKIPPED+=("$REPO_NAME (no yaml files)")
    continue
  fi
  
  # 이미 패치 브랜치가 있는지 확인 (clone 전에 체크)
  EXISTING_BRANCH=$(gh api "repos/${FULL_REPO}/branches/${BRANCH_NAME}" \
    --jq '.name' 2>/dev/null || echo "")
  if [[ -n "$EXISTING_BRANCH" ]]; then
    warn "  └ 이미 ${BRANCH_NAME} 브랜치 존재, 스킵"
    SUMMARY_SKIPPED+=("$REPO_NAME (branch exists)")
    continue
  fi

  # dry-run: clone 없이 워크플로우 파일 목록만 API로 확인
  if [[ "$DRY_RUN" == "true" ]]; then
    success "  └ [DRY-RUN] 워크플로우 ${WORKFLOW_COUNT}개 파일 패치 예정 (실제 내용 미검사)"
    SUMMARY_PATCHED+=("$REPO_NAME (${WORKFLOW_COUNT} files, dry-run)")
    continue
  fi

  info "  └ 워크플로우 ${WORKFLOW_COUNT}개 발견, clone 중..."

  # shallow clone
  if ! git clone --quiet --depth 1 \
    "https://github.com/${FULL_REPO}.git" \
    "$REPO_DIR" 2>/dev/null; then
    error "  └ clone 실패: ${FULL_REPO}"
    SUMMARY_ERRORS+=("$REPO_NAME (clone failed)")
    continue
  fi

  cd "$REPO_DIR"

  # 워크플로우 파일 패치
  WORKFLOW_DIR=".github/workflows"
  PATCHED_FILES=()

  for wf_file in "${WORKFLOW_DIR}"/*.yml "${WORKFLOW_DIR}"/*.yaml; do
    [[ -f "$wf_file" ]] || continue

    RESULT=$(python3 - "$wf_file" "$BOT_ACTORS" <<< "$PATCHER_SCRIPT")

    case "$RESULT" in
      "OK:patched")
        success "    ✓ $(basename "$wf_file") 패치됨"
        PATCHED_FILES+=("$wf_file")
        ;;
      "SKIP:already_patched")
        warn "    - $(basename "$wf_file") 이미 패치됨"
        ;;
      "SKIP:no_jobs_found")
        warn "    - $(basename "$wf_file") jobs 없음 (reusable workflow?)"
        ;;
    esac
  done

  if [[ ${#PATCHED_FILES[@]} -eq 0 ]]; then
    warn "  └ 패치할 파일 없음, 스킵"
    SUMMARY_SKIPPED+=("$REPO_NAME (nothing to patch)")
    cd - > /dev/null
    continue
  fi

  # 브랜치 생성 및 커밋
  git checkout -b "$BRANCH_NAME" --quiet
  git add "${PATCHED_FILES[@]}"
  git -c user.name="patch-bot" \
      -c user.email="patch-bot@localhost" \
      commit -m "$COMMIT_MSG" --quiet
  
  # push
  if ! git push origin "$BRANCH_NAME" --quiet 2>/dev/null; then
    error "  └ push 실패"
    SUMMARY_ERRORS+=("$REPO_NAME (push failed)")
    cd - > /dev/null
    continue
  fi
  
  # PR 생성
  PR_URL=$(gh pr create \
    --repo "$FULL_REPO" \
    --base "$DEFAULT_BRANCH" \
    --head "$BRANCH_NAME" \
    --title "$PR_TITLE" \
    --body "$PR_BODY" 2>/dev/null || echo "")
  
  if [[ -n "$PR_URL" ]]; then
    success "  └ PR 생성: ${PR_URL}"
    SUMMARY_PATCHED+=("$REPO_NAME → $PR_URL")
  else
    error "  └ PR 생성 실패"
    SUMMARY_ERRORS+=("$REPO_NAME (PR failed)")
  fi
  
  cd - > /dev/null
  echo ""

done <<< "$REPOS"

# ── 요약 ─────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  실행 요약"
echo "════════════════════════════════════════"
echo ""

if [[ ${#SUMMARY_PATCHED[@]} -gt 0 ]]; then
  success "패치 대상 (${#SUMMARY_PATCHED[@]}개):"
  for r in "${SUMMARY_PATCHED[@]}"; do echo "  • $r"; done
  echo ""
fi

if [[ ${#SUMMARY_SKIPPED[@]} -gt 0 ]]; then
  warn "스킵 (${#SUMMARY_SKIPPED[@]}개):"
  for r in "${SUMMARY_SKIPPED[@]}"; do echo "  • $r"; done
  echo ""
fi

if [[ ${#SUMMARY_ERRORS[@]} -gt 0 ]]; then
  error "오류 (${#SUMMARY_ERRORS[@]}개):"
  for r in "${SUMMARY_ERRORS[@]}"; do echo "  • $r"; done
  echo ""
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  warn "DRY-RUN 완료. 실제 적용하려면: ./patch-workflows-skip-bots.sh --apply"
fi
