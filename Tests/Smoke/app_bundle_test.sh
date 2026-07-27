#!/bin/bash

set -euo pipefail

workspace_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app_bundle="$workspace_root/AISpendBar.app"
info_plist="$app_bundle/Contents/Info.plist"
executable="$app_bundle/Contents/MacOS/AISpendBar"
resources="$app_bundle/Contents/Resources"

test -x "$executable"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$info_plist")" = "true"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" \
  = "com.ashercohen.AISpendBar"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$info_plist")" = "AI Spend"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")" = "AISpendBar"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$info_plist")" = "APPL"
test -f "$resources/AISpendBar_AISpendProviders.bundle/model-prices.json"
test -d "$resources/AISpendBar_AISpendBar.bundle"
codesign --verify --deep --strict "$app_bundle"
