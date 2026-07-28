#!/bin/bash

set -euo pipefail

workspace_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
app_bundle="$workspace_root/AISpendBar.app"
expected_bundle="$workspace_root/AISpendBar.app"

if [[ "$app_bundle" != "$expected_bundle" ]] \
  || [[ "$(dirname "$app_bundle")" != "$workspace_root" ]] \
  || [[ "$(basename "$app_bundle")" != "AISpendBar.app" ]]; then
  echo "Refusing to package an unexpected app path: $app_bundle" >&2
  exit 1
fi

cd "$workspace_root"
swift build -c release
release_dir="$(swift build -c release --show-bin-path)"

executable="$release_dir/AISpendBar"
executable_resources="$release_dir/AISpendBar_AISpendBar.bundle"
provider_resources="$release_dir/AISpendBar_AISpendProviders.bundle"

for required_path in "$executable" "$executable_resources" "$provider_resources"; do
  if [[ ! -e "$required_path" ]]; then
    echo "Missing release artifact: $required_path" >&2
    exit 1
  fi
done

if [[ -e "$app_bundle" ]]; then
  rm -rf -- "$app_bundle"
fi

mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
install -m 755 "$executable" "$app_bundle/Contents/MacOS/AISpendBar"
cp -R "$executable_resources" "$app_bundle/Contents/Resources/"
cp -R "$provider_resources" "$app_bundle/Contents/Resources/"
install -m 644 \
  "$workspace_root/Sources/AISpendBar/Resources/Info.plist" \
  "$app_bundle/Contents/Info.plist"

codesign --force --deep --sign - "$app_bundle"
echo "Packaged $app_bundle"
