# AI Spend Menu Bar App Design

## Summary

Build a native macOS menu bar app that reports metered AI spend for the current calendar month. The app combines enabled providers into one total, shows whether spend is on pace for multiple simultaneous monthly budgets, alerts when pacing is off, and drills down by provider and model.

The first usable version supports Cursor, Claude, and Codex/OpenAI. Its provider-adapter architecture must allow later integrations without changing aggregation, pacing, alerts, or UI.

## Goals

- Keep the current calendar-month AI spend visible in the macOS menu bar.
- Include metered and usage-based charges, including Cursor Enterprise usage-based charges.
- Exclude fixed subscription and seat fees.
- Support Cursor, Claude, and Codex/OpenAI in the first version.
- Reuse credentials and authenticated sessions already present on the Mac.
- Never ask the user to type, paste, or save a provider credential in this app.
- Prefer provider-reported billed cost and fall back to clearly labeled local estimates.
- Prevent actual and estimated records for the same usage from being counted twice.
- Show combined spend, provider spend, and model spend.
- Let the user enable or disable each provider.
- Evaluate any number of combined monthly budgets at the same time.
- Notify immediately when a budget changes to off pace, then at most once per local calendar day while it stays off pace.
- Keep provider data and normalized spend records on the Mac.

## Non-goals

- Tracking fixed ChatGPT, Claude, Cursor, or GitHub Copilot subscription fees.
- Managing provider credentials or creating admin API keys.
- Enforcing or changing provider-side budgets.
- Team allocation, chargeback, invoicing, or accounting exports in the first version.
- Claiming literal support for every AI provider in the first release.
- Routing or proxying AI requests.
- Synchronizing spend data between Macs.
- Converting non-USD billing into USD in the first version.

## Platform and Distribution

- Native Swift 6 application.
- SwiftUI settings and popover content, with AppKit status-item integration where needed.
- Minimum macOS version: macOS 14 Sonoma.
- Menu-bar-only application with no Dock icon during normal operation.
- USD is the only supported display and aggregation currency in the first version.
- The Mac's current calendar and timezone define the month boundary and notification day.

## Product Semantics

### What counts as spend

Spend is a usage-based monetary charge attributable to AI activity. The authoritative total includes provider-reported billed cost where available. It may also include calculated local-log estimates for uncovered usage, but those amounts are always marked as estimates.

Fixed subscription prices and per-seat charges never contribute to the total.

### Actual and estimated amounts

Every normalized record has a quality of `actual` or `estimated`.

- `actual`: returned by a provider billing, cost, analytics, or usage-event source that exposes a monetary charge.
- `estimated`: calculated from token or request usage using the app's versioned model-price catalog.

The headline displays the combined value and its split, such as `$621.07 actual · ~$63.20 estimated`. Every estimated amount uses approximation styling wherever it appears.

Actual data wins over estimated data for overlapping usage. If overlap cannot be established safely, the app excludes the ambiguous estimate and reports the exclusion in provider diagnostics. The app favors undercounting over double-counting.

### Provider toggles

Each provider has an independent enabled toggle.

When disabled, a provider:

- performs no credential discovery, local file reads, browser-session reads, or network requests;
- contributes nothing to totals, projections, budget evaluation, alerts, or breakdowns;
- retains its cached records locally so re-enabling it does not erase history.

## Architecture

The application has five primary boundaries:

1. **Provider adapters** discover reusable authentication, fetch actual cost data, scan supported local logs, and emit provider-native observations.
2. **Credential and source hosts** provide narrow, read-only access to allowlisted CLI files, app state, Keychain items, browser sessions, subprocesses, and HTTP domains.
3. **Spend normalizer and reconciler** convert observations into a shared record format, calculate estimates, and remove overlap.
4. **Monthly ledger and pacing engine** persist records, aggregate the current month, project month-end spend, and evaluate budgets.
5. **Menu bar, settings, and notifications** present the total and breakdowns, control providers and budgets, and deliver alerts.

Provider code depends on host protocols rather than directly accessing Keychain, browser internals, arbitrary files, or unrestricted network destinations. Adding a provider requires a descriptor, one or more source strategies, a normalizer, fixtures, and tests; it does not require changes to the ledger, pacing engine, or shared UI.

## Core Data Model

### Provider descriptor

A provider descriptor defines:

- stable provider ID;
- display name, icon, and color;
- default enabled state;
- ordered source strategies;
- allowlisted credential locations and network domains;
- capabilities, including actual cost, estimated cost, model breakdown, and daily history;
- diagnostic and dashboard links.

### Spend record

Each normalized spend record contains:

- stable record ID;
- provider ID;
- provider account or organization fingerprint that cannot reveal the raw credential;
- model identifier, or `unknown` when the source does not expose one;
- UTC interval start and exclusive end;
- amount in decimal USD;
- quality: actual or estimated;
- source strategy ID;
- source observation ID or deterministic content fingerprint;
- fetch timestamp;
- optional estimate metadata: token categories, unit prices, and price-catalog version.

Money uses decimal arithmetic. Floating-point values are not used for stored or aggregated currency.

### Budget

Each budget contains:

- stable ID;
- positive decimal USD limit;
- enabled state;
- creation timestamp;
- last evaluated pacing state;
- last immediate-alert transition timestamp;
- last reminder local-calendar date.

Budgets apply only to the enabled-provider combined total. Duplicate budget limits are rejected because they would produce indistinguishable alerts.

## Provider Sources

Every adapter runs its available strategies in priority order and records which source produced each amount. Credential discovery is read-only and restricted to known locations.

### Cursor

Priority:

1. Reuse an authenticated Cursor browser or application session to retrieve organization usage-based spend with model and usage-event detail.
2. Reuse an existing Cursor Admin API credential when one is already available to the process or in an allowlisted Cursor-owned credential location. The app does not create or store this key.
3. If neither source is available, report Cursor as unavailable; the first version does not invent Cursor cost from incomplete local request counts.

Only usage-based events contribute to spend. Included-in-plan usage and seat charges are excluded.

Cursor's documented `/teams/spend` endpoint supplies authoritative `spendCents` for the current calendar month. Its filtered usage events supply model, usage kind, token usage, and `tokenUsage.totalCents` for model attribution. The adapter ignores `requestsCosts` because it is denominated in request units, reconciles model-attributed cents to the team spend total, and assigns any positive unattributed remainder to model `unknown`. If model event costs conflict by exceeding the authoritative total, the app shows the provider total under `unknown` and reports a diagnostic rather than scaling or guessing.

### Claude

Priority:

1. Reuse an existing Anthropic Admin API key or OAuth token with `org:admin` scope to query organization cost reports.
2. Reuse an authenticated Claude Enterprise analytics session when it exposes cost data.
3. Scan known Claude Code session-log locations and calculate model-level estimates with the versioned price catalog.

Anthropic cost reports are requested in daily buckets and grouped by model or description when supported. API cost, web search, and code-execution cost types are included when metered. Subscription or seat costs are excluded.

Ordinary Claude Code login credentials may not have organization cost-report permission. In that case the adapter uses local estimates and explains why actual billing is unavailable.

### Codex/OpenAI

Priority:

1. Reuse an existing OpenAI organization admin credential to query `GET /organization/costs`.
2. Reuse an authenticated OpenAI dashboard browser session when it exposes organization cost data.
3. Scan known Codex session-log locations and calculate model-level estimates with the versioned price catalog.

OpenAI organization cost data is authoritative for the intervals it covers. Local Codex estimates fill only uncovered usage. ChatGPT or Codex subscription prices are excluded.

Ordinary Codex OAuth may expose usage limits without granting organization cost-report access. Usage-limit percentages do not become dollar spend.

## Fetch and Refresh Flow

The app refreshes:

- at launch;
- whenever the popover opens and the last attempt is older than one minute;
- every 15 minutes while running;
- on explicit user refresh;
- after a provider is enabled.

A refresh:

1. Captures the current local calendar-month interval.
2. Runs enabled provider adapters concurrently.
3. Applies a finite timeout to every credential, local-file, subprocess, browser, and HTTP operation.
4. Normalizes successful observations into daily provider/model records.
5. Reconciles actual and estimated coverage.
6. Atomically replaces records for the successfully refreshed source intervals.
7. Preserves the prior cache for failed providers.
8. Recomputes totals, provider/model breakdowns, projection, and every budget.
9. Schedules eligible notifications.

One provider's failure never cancels another provider's refresh.

## Reconciliation and Deduplication

Reconciliation occurs within the same provider and account fingerprint.

1. Exact source IDs or matching deterministic fingerprints are duplicates.
2. Actual records supersede estimated records with the same model and overlapping source usage IDs.
3. When source usage IDs do not exist, actual daily coverage supersedes estimates for the same provider, account, model, and intersecting time interval.
4. Estimates outside actual coverage remain included.
5. Ambiguous estimates that cannot be separated from actual coverage are excluded and counted in a diagnostic `excludedEstimatedAmount`.

This algorithm never reconciles records across different providers. Cursor spend routed to an upstream model remains Cursor spend because Cursor is the billing provider.

## Monthly Aggregation and Pacing

The current month is the half-open local-calendar interval from the first instant of the month through the first instant of the next month. Source timestamps are stored in UTC and assigned to the local month at aggregation time.

The projection is:

`projected month-end spend = spend so far / elapsed fraction of the month`

Elapsed fraction uses real elapsed seconds between local-calendar month boundaries, so daylight-saving changes do not skew the calculation. Projection starts after six elapsed hours on the first day to avoid extreme early-month noise. Before then, the UI shows `Collecting pace`.

Each enabled budget is evaluated independently:

- `on pace` when projection is less than or equal to the budget;
- `off pace` when projection is greater than the budget;
- `collecting` before projection is available;
- `unknown` when every enabled provider lacks current-month data.

A partial or stale total still produces a projection, but the UI labels that projection as partial. Notifications are suppressed when all contributing data is stale or when the total is unknown.

## Alerts

The app requests standard macOS notification permission when the user creates the first enabled budget.

For each budget:

- send an immediate notification on a transition from `on pace` or `collecting` to `off pace`;
- while it remains `off pace`, send at most one reminder per local calendar day;
- do not send the daily reminder in the same local day as the immediate transition alert;
- reset reminder eligibility after the budget returns to `on pace`;
- suppress alerts for disabled budgets, an unknown total, or an all-stale total.

Notifications include current spend, projected month-end spend, the affected budget, and the largest contributing provider. Multiple off-pace budgets may each alert because they represent separate user-configured levels, but each obeys its own throttle.

## Menu Bar and Popover

The status item displays the current combined monthly amount, for example `$684.27`. It dims and adds a warning indicator when the total is partial or stale.

The default popover shows:

- calendar month label;
- combined spend;
- actual and estimated split;
- projected month-end spend;
- one pacing row per enabled budget, sorted ascending;
- provider rows sorted by spend descending;
- last refresh time, refresh action, and settings action.

Selecting a provider opens its detail view with:

- provider total and share of combined total;
- actual and estimated split;
- models sorted by spend descending;
- amount and share for each model;
- explicit estimated badges;
- daily spend sparkline;
- source freshness and diagnostic link;
- provider dashboard link when available.

## Settings

### Providers

Each row shows:

- provider name and icon;
- enabled toggle;
- discovery state: actual available, estimate available, both, unavailable, stale, or error;
- active source names;
- last successful refresh;
- a diagnostics action.

Diagnostics list attempted source strategies and redacted outcomes. They never display cookies, tokens, keys, or raw authentication headers.

### Budgets

The user can add, enable, disable, edit, and remove any number of positive USD monthly budgets. The list shows current pacing state and projected margin for each budget.

### Privacy

The app explains each requested local-data, Keychain, browser, or notification permission. The user can disable browser-session discovery globally. Provider toggles remain the primary permission boundary.

## Storage and Privacy

- Normalized spend, budget, alert, and refresh metadata use a local SwiftData store.
- Raw credentials, cookies, and tokens are never copied into that store.
- Browser-session material remains in the browser or transient memory.
- Credential values are never logged.
- Logs redact authorization headers, cookie values, query secrets, user emails, and account IDs.
- Provider/account fingerprints use a one-way keyed digest stored in the app's Keychain.
- Local log scanning is restricted to documented, allowlisted paths for enabled providers.
- Network requests are restricted to provider descriptor domain allowlists.
- The app performs no analytics or telemetry in the first version.

## Failure and Staleness Behavior

- A failed refresh keeps the last successful records for that provider.
- Cached provider data is `stale` after twice the normal refresh interval: 30 minutes.
- The combined total is `partial` when any enabled provider is unavailable or stale.
- The popover identifies failing providers and shows the age of cached values.
- Authentication failures explain the missing credential scope or login state and link to provider diagnostics.
- Parsing failures preserve a redacted response-shape diagnostic but never raw sensitive payloads.
- Month rollover immediately changes the displayed aggregation interval. Prior records remain stored for reconciliation but are not shown in the first-version UI.

## Testing Strategy

### Provider adapter tests

- Parse sanitized Cursor usage-event fixtures and exclude included-plan and seat costs.
- Parse Claude cost reports by day, model, and cost type.
- Parse OpenAI organization cost buckets.
- Parse Claude Code and Codex local-log fixtures.
- Verify source priority, availability, timeout, fallback, pagination, and redaction.

### Ledger and reconciliation tests

- Aggregate decimal USD by month, provider, and model.
- Replace exact duplicate records.
- Let actual records supersede overlapping estimates.
- Preserve non-overlapping estimates.
- Exclude ambiguous estimates rather than double-count.
- Ensure disabling a provider removes it from every derived view without deleting cached records.

### Calendar and pacing tests

- Handle 28-, 29-, 30-, and 31-day months.
- Handle daylight-saving transitions and timezone changes.
- Roll over at the local first instant of a month.
- Suppress projection during the first six hours.
- Evaluate multiple budgets independently on every day of a month.
- Mark partial, all-stale, and unknown projections correctly.

### Alert tests

- Send an immediate alert exactly once per transition to off pace.
- Send no more than one reminder per local day per budget.
- Do not duplicate an immediate alert with a same-day reminder.
- Reset reminder eligibility after returning on pace.
- Suppress alerts for disabled budgets, unknown totals, and all-stale totals.
- Allow separate alerts for separate off-pace budgets.

### UI and integration tests

- Drive menu and settings view models with deterministic fake adapters and clocks.
- Verify headline actual/estimated splits and partial/stale indicators.
- Verify provider and model sorting and navigation.
- Verify provider toggles stop refresh work and update all derived totals.
- Run a smoke test that launches as a menu-bar-only app and opens the popover.

## Acceptance Criteria

The first version is complete when:

1. A user with existing Cursor, Claude, or Codex/OpenAI authentication can launch the app without entering credentials.
2. Each provider can be independently enabled or disabled.
3. Available actual costs and fallback local estimates for the current calendar month are combined without known double-counting.
4. The menu bar shows the combined USD total and the popover shows the actual/estimated split.
5. The user can drill down from total to provider to model.
6. The user can configure multiple combined monthly budgets.
7. Every budget shows its own pacing state against a shared month-end projection.
8. Off-pace budgets generate an immediate alert and no more than one reminder per subsequent local day.
9. Partial, stale, unavailable, and estimated data are visibly distinguishable.
10. Adapter, reconciliation, calendar, pacing, alert, and primary view-model tests pass.

## Research References

- [CodexBar architecture](https://github.com/steipete/CodexBar/blob/main/docs/architecture.md)
- [CodexBar provider authoring guide](https://github.com/steipete/CodexBar/blob/main/docs/provider.md)
- [Cursor Admin API usage events](https://docs.cursor.com/en/account/teams/admin-api)
- [Anthropic Cost Report API](https://platform.claude.com/docs/en/api/admin/cost_report)
- [Anthropic Admin API authentication](https://platform.claude.com/docs/en/manage-claude/overview)
- [OpenAI organization costs API](https://developers.openai.com/api/reference/resources/admin/subresources/organization/subresources/usage)
