#!/bin/bash

set -euo pipefail

latest_major=0
latest_minor=0
latest_patch=0
found_version=false

while IFS= read -r tag; do
  if [[ "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    major=$((10#${BASH_REMATCH[1]}))
    minor=$((10#${BASH_REMATCH[2]}))
    patch=$((10#${BASH_REMATCH[3]}))

    if [[ "$found_version" == false ]] \
      || ((major > latest_major)) \
      || ((major == latest_major && minor > latest_minor)) \
      || ((major == latest_major && minor == latest_minor && patch > latest_patch)); then
      latest_major="$major"
      latest_minor="$minor"
      latest_patch="$patch"
      found_version=true
    fi
  fi
done

if [[ "$found_version" == false ]]; then
  echo "v0.1.0"
else
  printf 'v%d.%d.%d\n' "$latest_major" "$latest_minor" "$((latest_patch + 1))"
fi
