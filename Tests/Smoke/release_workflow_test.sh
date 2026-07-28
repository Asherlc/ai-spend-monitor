#!/bin/bash

set -euo pipefail

workspace_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$workspace_root/.github/workflows/app-bundle.yml"

require_text() {
  local text="$1"
  if ! grep -Fq -- "$text" "$workflow"; then
    echo "Missing workflow contract: $text" >&2
    exit 1
  fi
}

require_text "contents: write"
require_text "group: app-release"
require_text "cancel-in-progress: false"
require_text "if: github.ref == 'refs/heads/master'"
require_text "runs-on: macos-15"
require_text "fetch-depth: 0"
require_text "swift test"
require_text "Tests/Smoke/release_version_test.sh"
require_text "Tests/Smoke/app_bundle_test.sh"
require_text "Scripts/next_release_version.sh"
require_text 'git tag --points-at "$GITHUB_SHA" --list'
require_text "grep -E '^v[0-9]+\\.[0-9]+\\.[0-9]+$'"
require_text 'echo "publish=$publish" >> "$GITHUB_OUTPUT"'
require_text "if: steps.release.outputs.publish == 'true'"
require_text 'gh release create "$RELEASE_VERSION" AISpendBar.zip'
require_text "--generate-notes"
