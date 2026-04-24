#!/usr/bin/env bash
# 전체 레포의 워크플로우 실행시간 집계 (최근 N개 기준)
# 요구사항: gh CLI, jq

LIMIT=20 # 레포당 최근 실행 건수
OUTPUT="workflow_stats.tsv"

echo -e "repo\ttotal_duration_sec\trun_count\tavg_sec" >"${OUTPUT}"

gh repo list --limit 100 --json nameWithOwner -q '.[].nameWithOwner' | while read -r repo; do
	echo "Processing: ${repo}" >&2

	durations=$(gh run list \
		--repo "${repo}" \
		--limit "${LIMIT}" \
		--json databaseId,status \
		--jq '.[] | select(.status == "completed") | .databaseId' 2>/dev/null)

	if [[ -z ${durations} ]]; then
		continue
	fi

	total=0
	count=0

	while read -r run_id; do
		# 개별 run의 실제 실행시간 (created_at ~ updated_at 차이)
		timing=$(gh api \
			"repos/${repo}/actions/runs/${run_id}" \
			--jq '((.updated_at | fromdateiso8601) - (.created_at | fromdateiso8601))' 2>/dev/null)

		if [[ -n ${timing} ]] && [[ ${timing} -gt 0 ]] 2>/dev/null; then
			total=$((total + timing))
			count=$((count + 1))
		fi
	done <<<"${durations}"

	if [[ ${count} -gt 0 ]]; then
		avg=$((total / count))
		echo -e "${repo}\t${total}\t${count}\t${avg}" >>"${OUTPUT}"
	fi
done

# 총합 기준 내림차순 정렬 출력
echo -e "\n=== Top repos by total workflow duration (sec) ==="
sort -t$'\t' -k2 -rn "${OUTPUT}" | column -t -s $'\t'
