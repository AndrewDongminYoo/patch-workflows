# Repository Guidelines

## Project Structure & Module Organization

This repository is a small Bash utility collection for managing GitHub Actions across many repositories. The root scripts are the product:

- `patch-workflows-skip-bots.sh` adds job-level conditions to skip Actions runs for bot PRs.
- `delete-bot-branches.sh` removes the remote cleanup branch created by the patch script.
- `workflow-execution-time.sh` aggregates recent workflow durations and writes `workflow_stats.tsv`.

Keep generated data such as `workflow_stats.tsv` separate from script logic. Tooling lives in `.trunk/trunk.yaml`.

## Build, Test, and Development Commands

Use the scripts directly from the repository root:

- `./patch-workflows-skip-bots.sh` runs the safe dry-run path.
- `./patch-workflows-skip-bots.sh --apply` clones, patches, pushes, and opens PRs.
- `./delete-bot-branches.sh` deletes remote `chore/skip-bot-pr-workflows` branches.
- `./workflow-execution-time.sh` refreshes `workflow_stats.tsv`.
- `trunk fmt` formats shell files with `shfmt`.
- `trunk check` runs repo checks such as `shellcheck`, `shfmt`, and secret scanning.

These scripts require an authenticated `gh` CLI. `patch-workflows-skip-bots.sh` also expects `git` and `python3`; `workflow-execution-time.sh` uses `jq`.

## Coding Style & Naming Conventions

Write Bash with `#!/usr/bin/env bash` and `set -euo pipefail`. Prefer lowercase, hyphen-separated script names ending in `.sh`. Use `UPPER_SNAKE_CASE` for configuration constants and short verb-based helper functions such as `info`, `warn`, and `error`.

Keep user-facing output and new comments in English. Run `trunk fmt` instead of hand-formatting.

## Testing Guidelines

There is no dedicated automated test suite yet. Validate changes with:

- `bash -n *.sh`
- `trunk check`
- the safest runtime path for the edited script, usually a dry run first

For any command that mutates remote repositories, prove the dry-run output is correct before using `--apply`.

## Commit & Pull Request Guidelines

Recent history follows Conventional Commit prefixes such as `feat:`, `fix:`, `docs:`, and `perf:`; keep using that pattern.

PRs should state which script changed, the operational impact, required CLI dependencies, and whether the change touches remote GitHub state. Include sample command output when behavior changes, especially for dry-run or destructive paths.
