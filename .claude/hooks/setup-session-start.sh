#!/bin/bash
# SessionStart hook for Claude Code cloud sessions: installs this repo's
# dependencies and tools so builds, linters and tests work from the first
# prompt. The container is snapshotted after the hook finishes, so later
# sessions reuse what it installed.
#
# Local sessions are left alone: developers manage their own installs.
set -euo pipefail

cat >/dev/null || true

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Ruby 3.3 for test/app_platform_test.rb is preinstalled; actionlint is the
# only other tool the validate workflow runs.
if ! command -v actionlint >/dev/null 2>&1; then
  GOBIN=/usr/local/bin go install github.com/rhysd/actionlint/cmd/actionlint@v1.7.12
fi
