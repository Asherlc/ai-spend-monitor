# GitHub Releases Design

## Goal

Distribute every successful `master` build of AI Spend as a durable GitHub
Release instead of a short-lived GitHub Actions artifact. Each release must
have a unique semantic version tag and a directly downloadable
`AISpendBar.zip` asset.

## Release trigger and versioning

The existing app-bundle workflow remains triggered by pushes to `master` and
manual workflow dispatches. A successful run determines the next version from
the repository's existing tags:

- If no tag matching `vMAJOR.MINOR.PATCH` exists, the first version is
  `v0.1.0`.
- Otherwise, the workflow selects the highest semantic version and increments
  its patch component by one.
- Major and minor versions are not changed automatically.

The workflow fetches full tag history before calculating the version. Release
runs are serialized so two nearby pushes cannot choose the same next version.
A manual dispatch follows the same rules and therefore also creates a new
patch release.

## Build and publication flow

The workflow keeps the existing quality gates:

1. Check out the repository with tag history.
2. Run the Swift test suite.
3. Package `AISpendBar.app`.
4. Run the app-bundle smoke test.
5. Create `AISpendBar.zip`.
6. Calculate the next patch version.
7. Create a Git tag and GitHub Release for the tested commit.
8. Attach `AISpendBar.zip` to the release.

The release title is the calculated version. GitHub-generated release notes
summarize commits since the preceding release. The workflow receives
`contents: write`, the minimum repository permission needed to create the tag,
release, and asset.

No release or tag is created if the build, tests, packaging, or smoke test
fails. If publication itself fails, rerunning the workflow must not overwrite
an unrelated release. The serialized workflow recalculates the next available
version from remote tags immediately before publication.

The app remains ad-hoc signed and unnotarized. This change improves
distribution and retention but does not change macOS trust behavior.

## README changes

The download instructions link to the repository's Releases page and tell
users to:

1. Open the latest release.
2. Download `AISpendBar.zip`.
3. Extract and move `AISpendBar.app` to `/Applications`.
4. Use the existing Control-click or Privacy & Security flow on first launch.

The README no longer directs users through workflow runs, expiring artifacts,
or a nested archive. Update instructions tell users to quit the running app,
download the latest GitHub Release, and replace the installed copy.

The build-from-source section remains unchanged because local packaging and
verification commands are unchanged.

## Verification

The implementation is verified with:

- syntax and structure checks for the workflow;
- the existing Swift tests;
- the existing app-bundle smoke test;
- inspection that the workflow has write permission, full tag checkout,
  serialized release execution, patch-version calculation, and release asset
  upload;
- inspection that the README links to GitHub Releases and accurately describes
  the current signing and installation behavior.

Creating a real GitHub Release is intentionally left to the next successful
run on `master`; local verification must not publish tags or releases.
