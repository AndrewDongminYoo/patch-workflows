#!/usr/bin/env bash
# patch-workflows-skip-bots.sh
#
# Adds an `if` condition to every job in every workflow file across all
# personal GitHub repositories so that dependency-bot PRs never trigger
# Actions runs, saving free-tier minutes.
#
# Requirements:
#   - gh CLI (https://cli.github.com) — must be authenticated
#   - git, python3
#
# Usage:
#   chmod +x patch-workflows-skip-bots.sh
#   ./patch-workflows-skip-bots.sh            # dry-run (default, no changes)
#   ./patch-workflows-skip-bots.sh --apply    # clone, patch, push, open PRs

set -euo pipefail
export GH_PAGER=""

# ── Configuration ────────────────────────────────────────────────────────────
BOT_ACTORS='["dependabot[bot]", "renovate[bot]", "snyk-bot", "allcontributors[bot]"]'
BRANCH_NAME="chore/skip-bot-pr-workflows"
COMMIT_MSG="ci: skip workflow runs on bot PRs"
PR_TITLE="ci: skip workflow runs on bot PRs"
PR_BODY='Adds an `if` condition to every job so that dependency-bot PRs (dependabot, renovate, etc.) do not trigger Actions runs, reducing unnecessary minutes usage.'

DRY_RUN=true
if [[ ${1-} == "--apply" ]]; then
	DRY_RUN=false
fi

# ── Color helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERR]${NC}   $*"; }

# ── Dependency check ─────────────────────────────────────────────────────────
for cmd in gh git python3; do
	if ! command -v "${cmd}" &>/dev/null; then
		error "${cmd} is not installed."
		exit 1
	fi
done

GH_USER=$(gh api user -q .login)
info "GitHub user: ${GH_USER}"
if [[ ${DRY_RUN} == "true" ]]; then
	warn "DRY-RUN mode — no changes will be made. Pass --apply to execute."
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

SUMMARY_PATCHED=()
SUMMARY_SKIPPED=()
SUMMARY_ERRORS=()

# ── Inline Python patcher ─────────────────────────────────────────────────────
# Inserts an `if:` condition under each job that does not already have one.
# Skips files that already contain the bot-filter expression.
PATCHER_SCRIPT=$(
	cat <<'PYEOF'
import sys
import re


def patch_workflow(content, bot_actors):
    condition = (
        f"!(github.event_name == 'pull_request' && "
        f"contains(fromJSON('{bot_actors}'), github.actor))"
    )

    if "fromJSON" in content and "github.actor" in content:
        return None, "already_patched"

    lines = content.splitlines(keepends=True)
    result = []
    i = 0
    patched = False
    in_jobs = False
    job_indent = None

    while i < len(lines):
        line = lines[i]
        stripped = line.rstrip()

        if re.match(r'^jobs\s*:', stripped):
            in_jobs = True
            result.append(line)
            i += 1
            continue

        if in_jobs:
            m = re.match(r'^( {2,4})([a-zA-Z_][a-zA-Z0-9_-]*)(\s*:\s*)$', stripped)
            if m:
                indent = len(m.group(1))
                if job_indent is None:
                    job_indent = indent

                if (len(line) - len(line.lstrip())) == job_indent:
                    result.append(line)
                    i += 1

                    peek = i
                    has_if = False
                    while peek < len(lines):
                        pl = lines[peek].rstrip()
                        if re.match(r'^ {' + str(job_indent) + r'}[a-zA-Z_]', pl):
                            break
                        if re.match(r'^ {' + str(job_indent + 2) + r'}if\s*:', pl):
                            has_if = True
                            break
                        peek += 1

                    if not has_if:
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

# ── Collect repository list ───────────────────────────────────────────────────
info "Fetching repository list..."
REPOS=$(gh repo list "${GH_USER}" \
	--limit 200 \
	--no-archived \
	--source \
	--json name,defaultBranchRef \
	--jq '.[] | "\(.name)|\(.defaultBranchRef.name // "main")"')

REPO_COUNT=$(echo "${REPOS}" | wc -l | tr -d ' ')
info "Found ${REPO_COUNT} repositories"
echo ""

# ── Per-repository processing ─────────────────────────────────────────────────
while IFS='|' read -r REPO_NAME DEFAULT_BRANCH; do
	FULL_REPO="${GH_USER}/${REPO_NAME}"
	REPO_DIR="${WORK_DIR}/${REPO_NAME}"

	info "Processing: ${FULL_REPO} (default branch: ${DEFAULT_BRANCH})"

	# Check for .github/workflows via HTTP status to avoid jq misreading 404 JSON
	WORKFLOW_API_RESPONSE=$(gh api "repos/${FULL_REPO}/contents/.github/workflows" \
		--include 2>/dev/null || true)

	HTTP_STATUS=$(echo "${WORKFLOW_API_RESPONSE}" | grep -m1 '^HTTP/' | awk '{print $2}' || true)
	HTTP_STATUS="${HTTP_STATUS:-0}"

	if [[ ${HTTP_STATUS} != "200" ]]; then
		warn "  └ No .github/workflows — skipping"
		SUMMARY_SKIPPED+=("${REPO_NAME} (no workflows)")
		continue
	fi

	WORKFLOW_COUNT=$(echo "${WORKFLOW_API_RESPONSE}" | tail -1 | python3 -c \
		"import sys,json; data=json.load(sys.stdin); print(len([f for f in data if f['name'].endswith(('.yml','.yaml'))]))" \
		2>/dev/null || echo "0")

	if [[ ${WORKFLOW_COUNT} == "0" ]]; then
		warn "  └ Directory exists but no yml/yaml files — skipping"
		SUMMARY_SKIPPED+=("${REPO_NAME} (no yaml files)")
		continue
	fi

	# Check whether the patch branch already exists (before cloning)
	BRANCH_STATUS=$(gh api "repos/${FULL_REPO}/branches/${BRANCH_NAME}" \
		-i 2>/dev/null | head -1 | awk '{print $2}' || true)
	if [[ ${BRANCH_STATUS} == "200" ]]; then
		warn "  └ Branch ${BRANCH_NAME} already exists — skipping"
		SUMMARY_SKIPPED+=("${REPO_NAME} (branch exists)")
		continue
	fi

	# Dry-run: report intent without cloning
	if [[ ${DRY_RUN} == "true" ]]; then
		success "  └ [DRY-RUN] ${WORKFLOW_COUNT} workflow file(s) would be patched"
		SUMMARY_PATCHED+=("${REPO_NAME} (${WORKFLOW_COUNT} files, dry-run)")
		continue
	fi

	info "  └ Cloning (shallow)..."

	if ! git clone --quiet --depth 1 \
		"https://github.com/${FULL_REPO}.git" \
		"${REPO_DIR}" 2>/dev/null; then
		error "  └ Clone failed: ${FULL_REPO}"
		SUMMARY_ERRORS+=("${REPO_NAME} (clone failed)")
		continue
	fi

	cd "${REPO_DIR}"

	WORKFLOW_DIR=".github/workflows"
	PATCHED_FILES=()

	for wf_file in "${WORKFLOW_DIR}"/*.yml "${WORKFLOW_DIR}"/*.yaml; do
		[[ -f ${wf_file} ]] || continue

		RESULT=$(python3 - "${wf_file}" "${BOT_ACTORS}" <<<"${PATCHER_SCRIPT}")

		case "${RESULT}" in
		"OK:patched")
			success "    ✓ $(basename "${wf_file}") patched"
			PATCHED_FILES+=("${wf_file}")
			;;
		"SKIP:already_patched")
			warn "    - $(basename "${wf_file}") already patched"
			;;
		"SKIP:no_jobs_found")
			warn "    - $(basename "${wf_file}") no jobs found (reusable workflow?)"
			;;
		esac
	done

	if [[ ${#PATCHED_FILES[@]} -eq 0 ]]; then
		warn "  └ Nothing to patch — skipping"
		SUMMARY_SKIPPED+=("${REPO_NAME} (nothing to patch)")
		cd - >/dev/null
		continue
	fi

	git checkout -b "${BRANCH_NAME}" --quiet
	git add "${PATCHED_FILES[@]}"
	git -c user.name="patch-bot" \
		-c user.email="patch-bot@localhost" \
		commit -m "${COMMIT_MSG}" --quiet

	if ! git push origin "${BRANCH_NAME}" --quiet 2>/dev/null; then
		error "  └ Push failed"
		SUMMARY_ERRORS+=("${REPO_NAME} (push failed)")
		cd - >/dev/null
		continue
	fi

	PR_URL=$(gh pr create \
		--repo "${FULL_REPO}" \
		--base "${DEFAULT_BRANCH}" \
		--head "${BRANCH_NAME}" \
		--title "${PR_TITLE}" \
		--body "${PR_BODY}" 2>/dev/null || true)

	if [[ -n ${PR_URL} ]]; then
		success "  └ PR created: ${PR_URL}"
		SUMMARY_PATCHED+=("${REPO_NAME} → ${PR_URL}")
	else
		error "  └ PR creation failed"
		SUMMARY_ERRORS+=("${REPO_NAME} (PR failed)")
	fi

	cd - >/dev/null
	echo ""

done <<<"${REPOS}"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  Summary"
echo "════════════════════════════════════════"
echo ""

if [[ ${#SUMMARY_PATCHED[@]} -gt 0 ]]; then
	success "Patched (${#SUMMARY_PATCHED[@]}):"
	for r in "${SUMMARY_PATCHED[@]}"; do echo "  • ${r}"; done
	echo ""
fi

if [[ ${#SUMMARY_SKIPPED[@]} -gt 0 ]]; then
	warn "Skipped (${#SUMMARY_SKIPPED[@]}):"
	for r in "${SUMMARY_SKIPPED[@]}"; do echo "  • ${r}"; done
	echo ""
fi

if [[ ${#SUMMARY_ERRORS[@]} -gt 0 ]]; then
	error "Errors (${#SUMMARY_ERRORS[@]}):"
	for r in "${SUMMARY_ERRORS[@]}"; do echo "  • ${r}"; done
	echo ""
fi

if [[ ${DRY_RUN} == "true" ]]; then
	echo ""
	warn "Dry-run complete. Run with --apply to execute."
fi
