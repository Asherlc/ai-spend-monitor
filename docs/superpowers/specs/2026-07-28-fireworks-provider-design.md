# Fireworks Provider Design

## Summary

AI Spend will add Fireworks as a first-class, default-enabled spend provider.
It will reuse a FireConnect login on macOS, discover every Fireworks account
available to that credential, and combine rated usage costs across those
accounts into the current-month total.

The integration will call Fireworks APIs directly. It will not shell out to
FireConnect or `firectl`, parse harness logs, or estimate costs from token
counts. FireConnect remains the setup path for securely acquiring and storing
the credential.

## Goals

- Include Fireworks actual spend in AI Spend totals, pacing, budgets, alerts,
  provider details, and diagnostics.
- Require only `fireconnect login` for normal macOS setup.
- Combine all Fireworks accounts accessible to the active credential.
- Preserve model and daily cost attribution where Fireworks returns it.
- Avoid persisting the Fireworks API key or account identifiers in AI Spend's
  ledger or diagnostics.
- Keep successful account data when another accessible account fails.

## Non-goals

- Installing or managing FireConnect from inside AI Spend.
- Configuring FireConnect harness routing.
- Monitoring Fireworks on Microsoft Foundry or Azure billing.
- Estimating Fireworks costs from Claude, Codex, Cursor, or other local logs.
- Reconstructing costs from `billingUsage` token counts or a local price
  catalog.
- Displaying per-account or per-user identity in the UI.

## Provider Model

Add `fireworks` to `ProviderID` and add a `Fireworks` descriptor after OpenAI.
The provider is enabled by default for new installations. Existing
installations gain an enabled Fireworks provider state through a one-time
default-state backfill; existing provider preferences remain unchanged.

Fireworks records are `actual` because the API returns rated dollar costs.
They participate in the same reconciliation, aggregation, freshness, pacing,
budget, and alert behavior as other provider records.

The provider row uses a flame-oriented SF Symbol and the existing provider
color/icon extension. Provider detail shows daily history and model rows from
the rated cost response. Unknown or unattributed model costs appear under
`unknown` instead of being discarded.

## Credential Discovery

Normal setup is:

1. Install FireConnect.
2. Run `fireconnect login`.
3. Launch or refresh AI Spend.

On macOS, FireConnect stores its API key in the system Keychain with service
`FireworksAI` and account `fireworks-api-key`. AI Spend will add that exact
credential to `CredentialHost`'s allowlist and read it through the existing
Keychain abstraction.

Credential precedence is:

1. `FIREWORKS_API_KEY`, when present in AI Spend's process environment.
2. The FireConnect Keychain item.

The environment variable is useful for development and managed launches.
Finder-launched production use will normally resolve the FireConnect Keychain
item. AI Spend keeps the credential only in memory for authenticated requests.
It never writes, logs, fingerprints directly, or exposes the key.

Fire Pass keys that cannot access account or billing APIs produce an
authorization diagnostic directing the user to sign in with a standard
Fireworks API key.

## Account Discovery

The client calls:

```text
GET https://api.fireworks.ai/v1/accounts
```

It follows `nextPageToken` until all accessible accounts are returned. Account
resource names are parsed to obtain the account ID required by billing
endpoints. The adapter creates a keyed account fingerprint from the Fireworks
credential plus account resource name using the existing
`AccountFingerprinter`; raw account names never enter spend records or
diagnostics.

An empty account list is an unavailable source, not a successful zero-cost
refresh.

## Rated Cost Queries

For every discovered account, the client calls:

```text
POST https://api.fireworks.ai/v1/accounts/{account_id}/usageCosts:query
```

The request uses:

- the current `MonthWindow` as inclusive `startTime` and exclusive `endTime`;
- `scope: "ACCOUNT"`;
- `groupBy: ["DAY", "MODEL"]`;
- `pageSize: 1000` (the service clamps values above its maximum);
- `pageToken` on subsequent pages.

The adapter maps each returned row to one `SpendRecord`:

- provider: `fireworks`;
- quality: `actual`;
- model: the response model, or `unknown`;
- interval: the row's day boundary, clamped to the requested month window;
- amount: the returned currency `units` plus `nanos`;
- source ID: `fireworks-usage-costs:<account-fingerprint>`;
- account fingerprint: derived locally;
- stable record and observation IDs: derived from the account fingerprint,
  interval, model, and scope.

Only USD rows are accepted because AI Spend currently supports USD only. A
non-USD row fails that account with a sanitized unsupported-currency
diagnostic.

The response-level subtotal is used as an integrity check. If grouped rows do
not equal the complete-query subtotal, the difference is added as an
`unknown` record for the query window so the provider total remains
authoritative while attribution remains honest.

## Permission Fallback

`ACCOUNT` scope requires account-administrator access. If an account query
returns HTTP 401 or 403:

1. Retry that account once with `scope: "SELF"` and the same day/model
   grouping.
2. If `SELF` succeeds, include those actual records and add a diagnostic
   stating that only authenticated-user spend is available for that account.
3. If `SELF` also fails, mark that account unavailable.

The UI must not describe a successful `SELF` fallback as full account spend.
Add a `ProviderFetchResult` coverage value with `complete` and `partial`
states, defaulting to `complete` for existing adapters. The Fireworks adapter
returns `partial` whenever at least one account is limited to personal scope
or failed entirely. `RefreshCoordinator` keeps the returned records available
but sets the combined summary's existing partial flag.

## Failure and Refresh Behavior

The adapter reports distinct source attempts for:

- `fireworks-credential`;
- `fireworks-account-discovery`;
- `fireworks-account-costs`;
- `fireworks-self-costs` when fallback occurs.

Cancellation is propagated immediately. Network, decoding, authorization, and
currency failures are sanitized through `Redactor`. Requests are restricted
by `HTTPClient` to `api.fireworks.ai`; redirects to other domains are rejected.

Each account is fetched independently. Successful accounts produce records
even when another account fails. Failed accounts do not enter
`refreshedSourceIDs`, so cached data for those account-specific source IDs is
retained. Successfully refreshed account sources replace their prior records.

The adapter returns unavailable when no credential exists, with setup text
that names `fireconnect login`. A credential with no accessible accounts is
also unavailable. A valid zero-cost response is successful with zero records
and a refreshed account-specific source ID, so freshness is retained without
inventing a ledger record.

## Privacy and Diagnostics

- The Fireworks key is read only from the process environment or the permitted
  Keychain item.
- Raw account names, display names, email addresses, user IDs, and API-key IDs
  are neither stored nor displayed.
- Account resource names are used only as input to the keyed fingerprint.
- Request URLs shown in diagnostics omit account path components.
- Fireworks response bodies are never included in error messages.
- Disabling Fireworks prevents credential, Keychain, file, subprocess, and
  network discovery through the existing provider enablement gate.

## Claude Code Deduplication

Claude Code can route requests through Fireworks' Anthropic-compatible
endpoint. Its local session log then produces a Claude estimated record while
Fireworks' usage-cost API produces the authoritative actual charge. Those two
records must not both contribute to spend.

Reconciliation recognizes this route only when the Claude log model is a
structurally valid Fireworks resource:

- `accounts/<owner>/models/<model>`;
- `accounts/<owner>/routers/<router>`.

The resource is canonicalized without its owner/account segment. When an
overlapping Fireworks actual record has the same canonical model identity, the
Fireworks record wins and the Claude local estimate is excluded. A plain
Claude model name is never assumed to be Fireworks traffic. If matching
Fireworks actual data is missing, stale, adjacent rather than overlapping, or
for another model, the Claude estimate remains so the app does not hide spend.

This is intentionally a narrow cross-provider exception to the normal
provider/account/model reconciliation boundary.

## Documentation

The README provider setup table will add Fireworks:

- credential: FireConnect Keychain login or `FIREWORKS_API_KEY`;
- fallback: authenticated-user rated costs when account-wide permission is
  unavailable;
- setup: install FireConnect from its official installer and run
  `fireconnect login`.

The provider limitations section will explain multi-account aggregation,
account-to-self scope fallback, billing freshness, and the lack of Azure
billing support.

## Testing

Tests will cover:

- `ProviderID` and built-in descriptor ordering;
- FireConnect Keychain and environment credential resolution;
- account-list decoding and pagination;
- usage-cost request method, URL, time range, scope, grouping, and pagination;
- money decoding from `units` and `nanos`;
- daily/model record normalization and stable identities;
- unknown-model and subtotal-difference reconciliation;
- aggregation across multiple accounts;
- one-account failure without loss of successful accounts;
- `ACCOUNT` authorization failure followed by `SELF` success;
- full authorization failure and Fire Pass guidance;
- non-USD rejection and error redaction;
- disabled-provider behavior through the refresh coordinator;
- existing-installation provider-state backfill;
- Fireworks provider presentation, icon, settings, and diagnostics;
- Claude Code estimates routed through explicit Fireworks model or router
  resources are superseded by matching Fireworks actual costs without
  suppressing ordinary Claude estimates;
- README and packaged runtime smoke coverage where provider enumeration is
  asserted.

All new production behavior follows red-green-refactor. The complete Swift
test suite, formatter lint, app packaging, bundle smoke test, and runtime
self-check must pass before release.

## References

- [FireConnect overview and installation](https://docs.fireworks.ai/ecosystem/fireconnect/overview#install)
- [FireConnect authentication and credential storage](https://docs.fireworks.ai/ecosystem/fireconnect/cli-reference)
- [Fireworks usage and cost breakdown](https://docs.fireworks.ai/accounts/exporting-usage-and-costs)
- [Fireworks usage-cost query API](https://docs.fireworks.ai/api-reference/query-usage-costs)
- [Fireworks list-accounts API](https://docs.fireworks.ai/api-reference/list-accounts)
