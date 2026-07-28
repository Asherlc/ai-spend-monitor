# GitHub Releases Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish every successful `master` build as a durable GitHub Release with an automatically incremented patch version and document the new download flow.

**Architecture:** A small tested shell utility calculates the next stable semantic version from tags supplied on standard input. The existing GitHub Actions workflow serializes release runs, executes all current quality gates, calls the utility after refreshing tags, and publishes the tested archive with GitHub CLI; the README points users to the resulting Releases page.

**Tech Stack:** Bash 3.2+, Git, GitHub Actions, GitHub CLI, Swift Package Manager, Markdown

## Global Constraints

- Releases are created only for `master`.
- The first release is `v0.1.0`; later releases increment only the patch component of the highest stable `vMAJOR.MINOR.PATCH` tag.
- Every successful `master` push and successful manual dispatch on `master` creates one release.
- Tests, packaging, and the existing app-bundle smoke test must pass before version calculation or publication.
- Release executions are serialized and must never cancel an in-progress release.
- The release contains `AISpendBar.zip`, uses GitHub-generated notes, and has a title equal to its version.
- The workflow uses `contents: write` and no broader permission.
- The app remains ad-hoc signed and unnotarized.
- Local verification must not create a tag or GitHub Release.
- All repository shell commands are prefixed with `rtk`.

---

## File Map

- `Scripts/next_release_version.sh` — pure standard-input-to-standard-output semantic patch-version calculator.
- `Tests/Smoke/release_version_test.sh` — behavioral tests for first, sequential, unordered, and malformed tag inputs.
- `Tests/Smoke/release_workflow_test.sh` — static contract test for permissions, concurrency, tag checkout, quality gates, version calculation, and release publication.
- `.github/workflows/app-bundle.yml` — builds, verifies, versions, and publishes `AISpendBar.zip`.
- `README.md` — end-user download, installation, trust, and update instructions.

### Task 1: Add the tested patch-version calculator

**Files:**
- Create: `Scripts/next_release_version.sh`
- Create: `Tests/Smoke/release_version_test.sh`

**Interfaces:**
- Consumes: zero or more newline-delimited Git tags on standard input.
- Produces: exactly one canonical `vMAJOR.MINOR.PATCH` line on standard output.
- Ignores: tags that do not exactly match stable `vMAJOR.MINOR.PATCH`.

- [ ] **Step 1: Write the failing behavioral test**

Create `Tests/Smoke/release_version_test.sh`:

```bash
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
assert_next_version "v3.0.0" $'junk\nv2.9.9\nv9.0.0-beta.1\n'
```

- [ ] **Step 2: Make the test executable and verify it fails**

Run:

```bash
rtk chmod +x Tests/Smoke/release_version_test.sh
rtk Tests/Smoke/release_version_test.sh
```

Expected: FAIL because `Scripts/next_release_version.sh` does not exist.

- [ ] **Step 3: Implement the minimal version calculator**

Create `Scripts/next_release_version.sh`:

```bash
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
```

- [ ] **Step 4: Make the calculator executable and run its test**

Run:

```bash
rtk chmod +x Scripts/next_release_version.sh
rtk Tests/Smoke/release_version_test.sh
```

Expected: PASS with exit status 0 and no output.

- [ ] **Step 5: Commit the versioning unit**

Run:

```bash
rtk git add Scripts/next_release_version.sh Tests/Smoke/release_version_test.sh
rtk git commit -m "ci: calculate automatic patch releases"
```

### Task 2: Publish the verified archive as a serialized GitHub Release

**Files:**
- Create: `Tests/Smoke/release_workflow_test.sh`
- Modify: `.github/workflows/app-bundle.yml`

**Interfaces:**
- Consumes: `Scripts/next_release_version.sh`, the tested `master` commit, repository tags, and the workflow-provided `GITHUB_TOKEN`.
- Produces: a GitHub Release whose tag and title are the calculated version and whose asset is `AISpendBar.zip`.

- [ ] **Step 1: Write the failing workflow contract test**

Create `Tests/Smoke/release_workflow_test.sh`:

```bash
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
require_text "fetch-depth: 0"
require_text "swift test"
require_text "Tests/Smoke/release_version_test.sh"
require_text "Tests/Smoke/app_bundle_test.sh"
require_text "Scripts/next_release_version.sh"
require_text 'gh release create "$RELEASE_VERSION" AISpendBar.zip'
require_text "--generate-notes"
```

- [ ] **Step 2: Make the contract test executable and verify it fails**

Run:

```bash
rtk chmod +x Tests/Smoke/release_workflow_test.sh
rtk Tests/Smoke/release_workflow_test.sh
```

Expected: FAIL at `contents: write` because the existing workflow only has read permission.

- [ ] **Step 3: Replace artifact upload with release publication**

Update `.github/workflows/app-bundle.yml` to this complete workflow:

```yaml
name: App release

on:
  push:
    branches:
      - master
  workflow_dispatch:

permissions:
  contents: write

concurrency:
  group: app-release
  cancel-in-progress: false

jobs:
  release:
    name: Build and release macOS app bundle
    if: github.ref == 'refs/heads/master'
    runs-on: macos-14
    timeout-minutes: 20

    steps:
      - name: Check out repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run tests
        run: |
          swift test
          Tests/Smoke/release_version_test.sh
          Tests/Smoke/release_workflow_test.sh

      - name: Package app
        run: Scripts/package_app.sh

      - name: Verify app bundle
        run: Tests/Smoke/app_bundle_test.sh

      - name: Create archive
        run: ditto -c -k --sequesterRsrc --keepParent AISpendBar.app AISpendBar.zip

      - name: Determine release version
        id: release
        run: |
          git fetch --force --tags origin
          release_version="$(git tag --list | Scripts/next_release_version.sh)"
          echo "version=$release_version" >> "$GITHUB_OUTPUT"

      - name: Publish GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
          RELEASE_VERSION: ${{ steps.release.outputs.version }}
        run: |
          gh release create "$RELEASE_VERSION" AISpendBar.zip \
            --target "$GITHUB_SHA" \
            --title "$RELEASE_VERSION" \
            --generate-notes
```

- [ ] **Step 4: Run local workflow checks**

Run:

```bash
rtk Tests/Smoke/release_version_test.sh
rtk Tests/Smoke/release_workflow_test.sh
rtk git diff --check
```

Expected: all commands exit 0. No tag or release is created locally.

- [ ] **Step 5: Commit the release workflow**

Run:

```bash
rtk git add .github/workflows/app-bundle.yml Tests/Smoke/release_workflow_test.sh
rtk git commit -m "ci: publish app with GitHub Releases"
```

### Task 3: Document GitHub Releases and verify the complete change

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the GitHub Release produced by Task 2.
- Produces: accurate download, first-launch, update, and source-build instructions for users.

- [ ] **Step 1: Replace the download instructions**

In `README.md`, replace the opening text and numbered list under
`## Download and install` with:

```markdown
Every successful push to `master` publishes a versioned
[GitHub Release](https://github.com/Asherlc/ai-spend-monitor/releases/latest)
containing the app bundle.

1. Open the latest GitHub Release.
2. Download `AISpendBar.zip`.
3. Open the archive to extract `AISpendBar.app`.
4. Drag `AISpendBar.app` into `/Applications`.
5. Control-click the app, choose **Open**, then confirm **Open**.
```

Keep the existing signing warning, first-launch explanation, app removal
instructions, privacy link, and build-from-source section. Replace the update
sentence with:

```markdown
To update, quit the running copy, download `AISpendBar.zip` from the latest
GitHub Release, and replace the existing app in `/Applications`.
```

- [ ] **Step 2: Check that obsolete artifact instructions are gone**

Run:

```bash
rtk rg -n "actions/workflows|Artifacts|nested archive|retention-days" README.md
rtk rg -n "releases/latest|AISpendBar.zip|ad-hoc signed|not notarized" README.md
```

Expected: the first command returns no matches; the second finds the Releases
link, archive name, and unchanged signing caveat.

- [ ] **Step 3: Run the complete local verification suite**

Run:

```bash
rtk swift test
rtk Tests/Smoke/release_version_test.sh
rtk Tests/Smoke/release_workflow_test.sh
rtk Scripts/package_app.sh
rtk Tests/Smoke/app_bundle_test.sh
rtk git diff --check origin/master...
rtk git status --short
```

Expected: Swift tests and all smoke tests pass; the package command creates an
ad-hoc-signed `AISpendBar.app`; the diff check reports no whitespace errors;
status contains only the intended workflow, script, test, README, spec, and
plan changes plus the ignored app bundle.

- [ ] **Step 4: Commit the documentation**

Run:

```bash
rtk git add README.md
rtk git commit -m "docs: download app from GitHub Releases"
```

- [ ] **Step 5: Review the final branch diff**

Run:

```bash
rtk git diff --stat origin/master...
rtk git diff --check origin/master...
rtk git log --oneline origin/master..HEAD
```

Expected: the branch contains the design, plan, version calculator and test,
release workflow contract test, workflow update, and README update with no
unrelated source changes.
