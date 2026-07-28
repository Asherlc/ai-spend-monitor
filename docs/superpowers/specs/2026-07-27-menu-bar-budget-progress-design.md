# Menu Bar Budget Progress Design

## Goal

Turn the AI Spend menu bar icon into a compact progress indicator showing current calendar-month spend against the first enabled budget.

“First” means the lowest enabled budget, matching the app’s existing budget ordering. Progress uses current spend, not projected month-end spend.

## User Experience

When current spend data and at least one enabled budget are available, the menu bar displays:

- a monochrome circular track;
- a progress arc beginning at 12 o’clock;
- a dollar sign centered inside the circle; and
- the existing formatted current-spend title beside the icon.

The progress arc represents:

```text
current calendar-month spend / lowest enabled budget
```

The rendered arc is clamped to the range from zero to one. Spend at or above the budget therefore displays a complete ring. The accessibility description retains the true, unclamped percentage so overspend remains explicit.

## Fallback and Health States

- With no enabled budget, retain the existing dollar-sign status icon.
- When current-month data is unavailable, retain the existing question-mark icon.
- When all data is stale, retain the existing warning icon.
- For partial but usable data, show the progress ring and retain the existing exclamation mark in the menu bar title.
- The existing formatted spend title and popover behavior do not otherwise change.

These fallbacks preserve more important data-health signals instead of presenting cached or unknown progress as current.

## Architecture

`AppModel` will expose a small, immutable menu bar budget-progress presentation value. It will:

1. use the first item in the already limit-sorted enabled budget evaluations;
2. divide the snapshot’s current monthly total by that budget limit;
3. expose both the clamped rendering fraction and the unclamped accessibility percentage; and
4. return no progress value when a fallback health state or missing budget applies.

A focused SwiftUI menu bar icon view will render the circular track, trimmed progress arc, and centered dollar sign. `AISpendBarApp` will select this view when progress is available and retain the existing SF Symbol fallback otherwise.

The progress calculation remains separate from SwiftUI rendering so its selection, arithmetic, clamping, and fallback behavior can be unit tested directly.

## Accessibility

The custom icon will have an accessibility label describing:

- the percentage of the budget used, including percentages over 100%; and
- the formatted limit of the selected budget.

The visual progress arc will not be the only source of budget information because the popover continues to show complete budget rows and pacing details.

## Testing

Test-driven implementation will cover:

- selecting the lowest enabled budget;
- calculating ordinary current-spend progress;
- clamping the rendered fraction at 100% while retaining the true overspend percentage;
- returning no progress for no enabled budget;
- returning no progress for unavailable data;
- returning no progress when all data is stale; and
- continuing to expose progress for partial but usable data.

After focused tests pass, run the full Swift test suite and Swift formatting lint.

## Repository Integration

The feature branch is currently based on `origin/master`, which contains the CI and documentation commit but not the application source. The complete application history is available on local `master`. Before test-first implementation, merge local `master` into the current feature branch without renaming the branch, preserving both histories and resolving any documentation overlap narrowly.

## Out of Scope

- Reordering budgets or adding a user-selected primary budget.
- Using projected month-end spend as progress.
- Adding color to the menu bar item.
- Changing budget notifications, pacing calculations, or popover budget rows.
- Displaying numeric percentage text directly in the menu bar.
