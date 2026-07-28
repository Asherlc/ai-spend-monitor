# Budget Exhaustion Forecast Design

## Summary

Add a CodexBar-style exhaustion forecast to each enabled monthly budget. The
app treats the calendar month as the usage window, the budget limit as the
window capacity, and month-end as the reset. At the current average burn rate,
each budget reports either when it will be exhausted before month-end or that
it will last through the month.

## Goals

- Show when each enabled budget is projected to be reached.
- Match CodexBar's burn-down semantics rather than introduce a new forecasting
  model.
- Reuse the pacing engine's current month-to-date linear burn rate.
- Keep forecast behavior consistent in the popover and budget settings.
- Preserve the existing projected month-end amount, pacing state, and
  projected under/over margin.

## Non-goals

- Historical smoothing, regression, confidence intervals, or run-out
  probabilities.
- Provider-specific budget forecasts.
- Forecasting beyond the current calendar month.
- Changing budget alerts or notification thresholds.
- Changing the six-hour collection period.

## Product Semantics

The forecast follows CodexBar's quota-window model:

- The monthly budget is the available capacity.
- Spend so far is the used capacity.
- The elapsed portion of the calendar month is the elapsed usage window.
- The first instant of the next month is the reset.
- The observed burn rate is `spend so far / elapsed seconds`.
- The exhaustion interval is
  `(budget limit - spend so far) / observed burn rate`.

For each enabled budget:

1. If spend is already greater than or equal to the limit, report
   `Budget reached`.
2. If the exhaustion date is before month-end, report
   `Projected to reach <date>`.
3. If the exhaustion date is at or after month-end, report
   `Lasts through month`.
4. During the existing six-hour collection period, report `Collecting pace`.
5. Without current-month data, report `No current data`.

An exhaustion exactly at month-end counts as lasting through the month because
the budget window resets at that boundary.

The app does not show an extrapolated exhaustion date in a later month. This
matches CodexBar's behavior of reporting that capacity lasts until reset rather
than projecting beyond the current usage window.

## Architecture

`PacingEngine` remains the single owner of budget forecasting. It calculates
the exhaustion result at the same time it calculates month-end projection,
budget pacing state, and projected margin.

`BudgetEvaluation` gains a forecast value with three meaningful outcomes:

- already reached;
- projected exhaustion at a concrete `Date` before month-end;
- lasts through month-end.

Collecting and unavailable states continue to be represented by
`BudgetPacingState`; they do not receive an exhaustion forecast.

The forecast value is data, not preformatted display text. This keeps date
formatting and localization in the UI while allowing the popover and settings
to share the calculation.

## UI

The popover budget row keeps its current title and right-aligned projected
under/over amount. A linear progress bar shows current spend against the
budget and clamps to completely full at 100% or above. Its secondary state
label becomes:

- `Budget reached`
- `Projected to reach Aug 18`
- `Lasts through month`
- `Collecting pace`
- `No current data`

The settings budget row uses the same forecast label and progress bar alongside
its existing pacing and margin details. No new controls or settings are added.

The menu-bar budget circle remains visible at 100% or above and uses a native
filled symbol for the completed state so macOS does not drop the custom
full-circle stroke from the status-item label.

Concrete dates use the user's current locale and timezone. The label includes
the month and day so it remains understandable near a month boundary.

## Data Flow

1. A refresh captures `now`, the current `MonthWindow`, current spend, and
   enabled budgets.
2. `PacingEngine` completes the existing six-hour and data-availability
   checks.
3. It computes the current average spend rate from elapsed real seconds.
4. For each budget, it compares current spend with the limit.
5. For a budget with remaining capacity, it divides that capacity by the burn
   rate and adds the interval to `now`.
6. It compares the resulting date with `MonthWindow.end` and stores either a
   concrete pre-reset reach date or the lasts-through-month outcome.
7. The popover and settings format the stored result for display.

## Edge Cases

- Zero measured spend after the collection period lasts through the month;
  there is no finite exhaustion date.
- A budget equal to current spend is already reached.
- A forecast equal to the exclusive month-end boundary lasts through the
  month.
- Decimal arithmetic remains in use for money. Conversion to elapsed seconds
  occurs only when producing the date interval.
- Partial or stale data retains the app's existing warning treatment. The
  forecast uses the same visible combined spend and is therefore no more
  authoritative than the existing month-end projection.
- Disabled budgets remain excluded from evaluations and forecasts.

## Testing

Core pacing tests will verify:

- a concrete exhaustion date before month-end;
- a budget that lasts through month-end;
- a budget already reached;
- exact exhaustion at month-end;
- zero spend after collection;
- no forecast while collecting;
- no forecast without data;
- independent forecasts for multiple sorted budgets.

UI-facing formatting tests will verify the three forecast labels and localized
date shape without relying on the machine's current date or timezone.

Existing pacing, margin, alert, and menu-bar progress tests must continue to
pass unchanged except for constructor updates required by the added forecast
value.
