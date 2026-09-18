# Icons in the opened macOS menu

## Component and cause

The native hierarchy is `StatusItemController.show()` → `NSStatusItem.menu` →
`rebuild(menu:now:)` → `headerItem(for:now:)`. The `NSMenuItem` created by
`headerItem` is the row containing `Claude — 100%` or `Codex — 23%`.

The previous implementation assigned `NSMenuItem.image` correctly but did not set
image visibility. On this machine's macOS 27, AppKit normally hides menu images
under the default `.automatic` preference. This behavior is documented in the
installed macOS SDK's `NSMenuItem.h`. The previous tests inspected the assigned
images and rendered them in image views, so they missed the actual menu's policy.
An opened native-menu capture reproduced both provider rows without icons.

`setProviderImage(_:on:)` now assigns the existing glyph image and, on macOS 27
and later, sets `preferredImageVisibility = .visible`. Earlier macOS versions
continue using their existing native image support. The same helper handles
already-existing local model row icons. It only affects rows carrying provider
artwork, leaving command image visibility at its default.

The setting is accessed through Objective-C key-value coding (`.visible` has
raw value `1`). This preserves compilation with the macOS 26 SDK used by the
repository's CI while still applying the policy when that build runs on macOS
27. The runtime availability check keeps older systems on their existing path.

## Mapping and scope

Provider snapshots continue to supply `displayName` and `glyph`. Claude uses
`.claude`; Codex uses `.openai`; Gemini API uses `.geminiSpark`; Antigravity uses
`.antigravity`. Every other header uses its adapter's existing glyph. The shared
`ProviderGlyph` asset/outline mapping and 16-point template renderer are reused
without modification. Missing artwork still returns `nil`.

The dropdown fix changes:

- `Sources/App/StatusItemController.swift`: explicitly show provider images in native dropdown rows on macOS 27.
- `Tests/MenuBarRefreshTests.swift`: assert provider image visibility and unchanged command rows.
- `Tests/StatusItemMenuVisualTests.swift`: add an opt-in test that opens the actual status-item menu in the Codenotch application host, for external screenshot capture.
- This document: record the rendering issue, minimal fix and visual verification.
- `docs/design/menu-dropdown-*.png`: captured native Light/Dark menus for review.

The status bar artwork, provider selection settings, quota/reset calculations,
monitoring, refresh methods and menu command actions were not changed by this
follow-up. Earlier work in the checkout remains intact.

## Visual verification

The Codenotch application host was launched through XCTest. Its production
`StatusItemController` created an actual `NSStatusItem` and menu; calling that
item's status bar button opened the native menu. This is not a mockup or a
separately drawn view. Example usage was injected to verify the requested
`Claude — 100%` and `Codex — 23%` rows without making live account requests.

The native menu was captured and visually inspected with all existing
`ProviderGlyph` cases, including every provider and local model brand that can
appear. Each available logo is visible directly before its name, inside the
native image column, with a consistent 16-point layout. Secondary usage lines
and Refresh all / Settings / Quit retained their existing presentation/actions.

After building, the normal Codenotch application was also launched from the
standard Xcode Debug product directory. Its actual account menu was opened
through its existing status bar button and captured in both appearances. These
captures show Claude at 100% and Codex at its current account reading, with
both logos and the original secondary usage rows visible.

The check switched the system between Light and Dark appearance, since remote
native menus follow the system's appearance, and restored the user's original
Light setting afterwards. Both captures show correctly tinted logos. Existing
2x image-rendering tests also verify the Retina path and missing-asset behavior.

Native fixture captures are included for reviewers:

- [Requested example values, Light Mode](design/menu-dropdown-examples-light.png)
- [Requested example values, Dark Mode](design/menu-dropdown-examples-dark.png)
- [Every glyph, Light Mode](design/menu-dropdown-all-glyphs-light.png)
- [Every glyph, Dark Mode](design/menu-dropdown-all-glyphs-dark.png)

The current-account captures remain local; the committed images use fixture data.

The opt-in test uses `TEST_RUNNER_CODENOTCH_MENU_VISUAL_OUTPUT` when launched by
`xcodebuild`, pointing to a fresh output directory. It emits `.prepare` markers
for the capture runner to set system appearance, waits for `.prepared`, opens
the native menu, then emits `.ready`
with its process ID. The external runner captures that process's actual menu
window into the corresponding PNG. Capture runs outside the test host because
that host does not have a screen-recording grant. Ordinary test runs skip this
interactive check.

Native menu verification and the associated icon, local-model menu and status
bar compatibility checks completed with **45 tests, zero failures**. The source
build succeeded, and the normal rebuilt application remains running.
