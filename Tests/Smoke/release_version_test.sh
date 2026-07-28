#!/bin/bash

set -euo pipefail

workspace_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
version_script="$workspace_root/Scripts/next_release_version.sh"

assert_next_version() {
  local expected="$1"
  local tags="$2"
  local actual
  actual="$(printf '%s' "$tags" | "$version_script")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected $expected, got $actual for tags: $tags" >&2
    exit 1
  fi
}

assert_next_version "v0.1.0" ""
assert_next_version "v0.1.1" $'v0.1.0\n'
assert_next_version "v1.10.4" $'v1.9.9\nv0.50.0\nv1.10.3\n'
assert_next_version "v2.9.10" $'junk\nv2.9.9\nv9.0.0-beta.1\n'
