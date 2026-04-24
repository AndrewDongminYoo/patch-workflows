# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Bash utilities for bulk-managing GitHub Actions workflows across a portfolio of personal repositories. The main use case is adding job-level `if:` conditions to skip CI runs triggered by dependency bots, saving GitHub Actions minutes on the free tier.

## Commands

### Running Scripts

```bash
# Dry-run (reports what would be patched, no changes made)
./patch-workflows-skip-bots.sh

# Apply patches: clone repos, insert bot-skip conditions, push PRs
./patch-workflows-skip-bots.sh --apply

# Delete the patch branches created by the above
./delete-bot-branches.sh

# Analyze workflow run durations across all repos → outputs workflow_stats.tsv
./workflow-execution-time.sh
```

### Linting & Formatting

```bash
# Validate shell syntax only
bash -n *.sh

# Run all checks (shellcheck + trufflehog + git-diff-check)
trunk check

# Auto-format shell scripts with shfmt
trunk fmt
```

Trunk runs `trunk-fmt-pre-commit` and `trunk-check-pre-push` hooks automatically.

## Architecture

### Script Structure

Each script follows the same pattern:

1. `set -euo pipefail` + constants block (`UPPER_SNAKE_CASE`)
2. Color helper functions: `info()`, `success()`, `warn()`, `error()`
3. `gh` CLI calls with `export GH_PAGER=""` to suppress pager
4. Batch processing loop over all user repos via `gh repo list --limit 200`

### YAML Patching (patch-workflows-skip-bots.sh)

The script embeds a Python script via heredoc to handle YAML manipulation. Python is used instead of `sed`/`awk` to correctly handle multi-line YAML job blocks. The condition inserted is:

```yaml
if: "!(github.event_name == 'pull_request' && contains(fromJSON(['dependabot[bot]', 'renovate[bot]', 'snyk-bot', 'allcontributors[bot]']), github.actor))"
```

Files already containing this condition are skipped (idempotent). Reusable workflows (no `jobs:` block) are also skipped.

### Generated Data

`workflow_stats.tsv` is generated output (not source). Format: `repo\ttotal_duration_sec\trun_count\tavg_sec`, sorted by total duration descending.

## Dependencies

- `gh` CLI — authenticated with GitHub (`gh auth login`)
- `git`
- `python3` — for inline YAML patching
- `jq` — for JSON parsing in analytics script
- `bash` 4.0+

## Conventions

- Script filenames: lowercase, hyphen-separated (e.g., `patch-workflows-skip-bots.sh`)
- Variables: `UPPER_SNAKE_CASE` for script-level constants, `lower_case` for locals
- Branch name for patches: `chore/skip-bot-pr-workflows`
- Commit style: Conventional Commits (`ci:`, `chore:`, `feat:`, `fix:`, `docs:`)
- Trunk manages shellcheck/shfmt; do not add inline `# shellcheck disable` unless absolutely necessary
