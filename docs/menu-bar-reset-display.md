# Menu bar reset display

Settings → Appearance now has a **Menu Bar** section with a native segmented
**Reset display** picker: **Reset Date** and **Time Remaining**. It uses the
same grouped Form and segmented Picker pattern as the existing Notch section.
The existing Notch reset preference stays independent.

The new `Preferences.menuBarResetTimeFormat` property is persisted through
the existing UserDefaults store under `menuBarResetTimeFormat` in the
`com.vinz.codenotch` domain. Its default is `ResetTimeFormat.automatic`
(**Reset Date**) for new installations, upgrades, and unrecognized stored values.
The stored values are `automatic` and `remaining`; reset timestamps remain Dates.

Previously, dropdown window reset copy came from `StatusItemController.windowLine`
calling `ResetCopy.text`. The top bar always called `ResetCopy.countdown`, even
though the dropdown used the date-oriented default. The default now gives the
top bar a compact reset date, as requested. Dropdown date behavior is preserved
exactly, including its existing rounded minutes under an hour, localized weekday
and time within a week, distant month/day, and “Resetting…” after expiration.

`ResetCopy.menuBarText` now receives the timestamp, mode and compact/detail
context. Date detail calls the existing `text` method. Its absolute date value
was extracted into a shared private `dateValue` helper so the compact bar can
reuse the same formatting without stripping words from localized strings.
Relative detail adds “Resets in” to the same compact countdown the bar shows.
Durations are calculated from the provider Date minus the current Date:
`<1m`, `42m`, `3h 21m`, or `2d 4h`. Minutes beside hours retain the existing
two-digit padding to keep the bar width stable. No seconds or separate countdown
state are stored. Missing/invalid dates are omitted from detail and shown as a
dash in the bar; expired resets retain the existing resetting state.

Every window and blocked-reset line uses the selected mode generically.
`AppDelegate` forwards preference publications directly to the status controller,
which immediately updates its button and any open menu from existing snapshots.
There are no provider-specific formatting branches.

The status controller's existing one-shot presentation timer now updates both
the button and open menu. It considers all menu windows and blocked resets,
including weekly limits and the icon-only bar. It runs in the main run loop's
common modes, wakes at the next minute boundary or expiration, and redraws locally.
The timer and preference handler never call either refresh handler. The provider
store, API requests, polling intervals, reset-boundary refresh, monitoring,
selection, icons and menu actions were not changed.

## Verification

`make build` succeeded. The final `make test` run passed **1,674 tests**, with
**zero failures** and four existing opt-in tests skipped. The new tests cover
duration boundaries, missing/non-finite/unrepresentable/expired timestamps,
exact date-copy preservation, independent preference defaults and persistence,
every ProviderGlyph and window, blocked resets, immediate open-menu updates,
real NSStatusItem updates, timer advancement without refresh calls, and new
snapshots arriving during countdowns. Existing provider polling, refresh, icons,
visibility, local-runtime, localization and rendering regression tests passed.

The rebuilt normal application was launched with its existing Claude and Codex
accounts. The actual Appearance segmented control was selected through its
native accessibility action. Its stored preference, status-controller mode and
status button changed immediately. Screenshots of the actual status bar and
opened native dropdown verify Claude Current session / All models and Codex
5h / Weekly in both modes, including the multi-day weekly duration. Light and
Dark native-menu appearances were inspected, with the original system appearance
restored afterward. The Settings panel retains its existing dark presentation.

The normal app was terminated and relaunched with Time Remaining selected;
both the loaded preference and status-controller mode remained `remaining`,
and its status button showed countdowns. The app was then returned to the
requested Reset Date default. Other providers were verified through generic
fixtures in the running application test host; their live accounts were not enabled.
A screenshot of the new Appearance section is included in
`docs/design/menu-bar-reset-display.png`. Current-account usage screenshots and
debugger verification logs are kept locally
outside the repository.

## Changed files

| File | Change |
| --- | --- |
| `Sources/Settings/SettingsView.swift` | New Appearance → Menu Bar section and picker |
| `Sources/Settings/Preferences.swift` | Published preference, persistence key and default |
| `Sources/App/AppDelegate.swift` | Initial mode and preference subscription |
| `Sources/App/StatusItemController.swift` | Shared menu formatting, immediate updates and local timer |
| `Sources/App/StatusItemSummary.swift` | Mode-aware compact reset value, tooltip and scheduling |
| `Sources/Model/ResetCopy.swift` | Shared menu presentation, reused dates, compact days and validation |
| `Sources/Model/UsageModel.swift` | Mode-aware blocked-reset copy |
| `Sources/Localizable.xcstrings` | New localizable English source keys |
| `Tests/MenuBarResetDisplayTests.swift` | New behavior and native status-item tests |
| `Tests/StatusItemSummaryTests.swift` | Existing countdown tests explicitly select remaining mode |
| `README.md` | Describe the new preference |
| `docs/menu-bar-reset-display.md` | Implementation and verification report |
| `docs/design/menu-bar-reset-display.png` | Actual Appearance section screenshot |
