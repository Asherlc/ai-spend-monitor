# AI Spend

AI Spend is a native, menu-bar-only macOS app for seeing current calendar-month
metered AI spend in one place. It combines enabled Cursor, Claude, and
Codex/OpenAI sources, shows provider and model breakdowns, projects month-end
spend, and evaluates multiple budgets independently.

The first version requires macOS 14 Sonoma or later and displays USD only.

## What the total means

The app counts usage-based monetary charges and excludes fixed subscriptions,
seat fees, and included-in-plan usage. Provider-reported billing data is marked
**actual**. Usage reconstructed from supported local Claude Code or Codex logs
and the bundled, versioned model-price catalog is marked **estimated** and shown
with an approximation indicator.

Actual data takes precedence over overlapping estimates. When overlap cannot be
separated safely, the ambiguous estimate is excluded rather than risking double
counting. Provider and model rows retain the actual/estimated distinction.

This is a monitoring aid, not an invoice or accounting export.

## Data sources and limitations

The shipped adapters attempt these sources:

1. **Cursor:** `CURSOR_ADMIN_API_KEY` supplies actual team spend and model
   attribution through Cursor's documented Admin API. An existing Cursor app
   session can be detected for diagnostics, but session-based billing retrieval
   is explicitly unsupported because Cursor exposes no documented app-session
   billing endpoint. Cursor has no local-log estimate fallback. Only usage-based
   team spend is included.
2. **Claude:** `ANTHROPIC_ADMIN_KEY`, or `ANTHROPIC_OAUTH_TOKEN` when the admin
   key is absent, supplies actual organization cost reports. Supported local
   Claude Code session logs are then scanned for uncovered estimates. No Claude
   Enterprise browser/session billing integration is wired in this release.
3. **Codex/OpenAI:** `OPENAI_ADMIN_KEY` supplies actual organization cost
   reports. Supported local Codex session logs are then scanned for uncovered
   estimates. No OpenAI dashboard-session billing integration is wired in this
   release.

Ordinary CLI logins often authorize product use but do not include organization
billing scope. In that case actual billing can be unavailable even while the CLI
works. Normal Claude Code and Codex CLI login state is not treated as an admin
billing credential; Claude and Codex may still show local estimates. Usage-limit
percentages are not converted into dollar spend.

Data can be partial when a provider is unavailable or stale. Cached data is kept
after a failed refresh and becomes stale after 30 minutes. Pacing begins after
the first six elapsed hours of the month; before that the app shows
“Collecting pace.”

## Providers, budgets, and alerts

Each provider has an independent toggle in Settings. Disabling one prevents its
credential discovery, local-file reads, browser discovery, and network work; it
also removes that provider from totals and pacing without deleting cached
history.

Add any number of distinct positive monthly budgets, such as `$500` and
`$1,500`. All enabled budgets compare independently against the same combined
month-end projection. When a budget changes to off pace, the app sends an
immediate notification. While it remains off pace, it sends at most one reminder
per subsequent local calendar day. Alerts are suppressed for unknown or
entirely stale data.

macOS notification permission is requested only when the first enabled budget
is created. Provider access is read-only.

## Privacy

Spend records, budgets, alert state, and refresh metadata stay in the app's
local Application Support directory. AI Spend has no analytics or telemetry.
It does not ask you to paste credentials and does not copy credentials, browser
cookies, or tokens into its ledger. Credential and browser discovery is limited
to known provider locations, and network access is restricted to provider
domains. Browser-session discovery can also be disabled globally.

Diagnostics show source strategy outcomes and sanitized failure descriptions.
Authorization headers, cookies, keys, query secrets, emails, and account
identifiers are redacted. A diagnostic such as “admin billing scope unavailable”
usually means the existing login is valid but cannot read organization costs;
it is not a request to enter that credential into AI Spend.

## Build and test

Install Xcode with the macOS 14 SDK or newer, then run:

```bash
swift build
swift test
swift format lint --recursive Sources Tests Package.swift
```

The app refreshes on launch, every 15 minutes while running, when an eligible
popover opens, after enabling a provider, and on manual refresh.

## Package and launch

Create a release build and an ad-hoc-signed app bundle:

```bash
bash Scripts/package_app.sh
bash Tests/Smoke/app_bundle_test.sh
open AISpendBar.app
```

`Scripts/package_app.sh` only recreates `AISpendBar.app` at the repository root.
The smoke test verifies its executable, menu-bar-only metadata, resource
bundles, decoded price catalog through a credential-free packaged runtime
self-check, and code signature. The self-check exits before app initialization,
provider discovery, network work, or notification permission. Because
`LSUIElement` is enabled, the packaged app runs without a normal Dock icon. Quit
it from Activity Monitor or with
`pkill -x AISpendBar` during local development.

The local ledger is stored beneath:

```text
~/Library/Application Support/AISpendBar/
```

Use the Settings privacy screen to reveal the exact active local-data path.
