# Menu bar icons and usage freshness

## Implementation

The menu opened by the macOS status item is an AppKit `NSMenu`, implemented in
`Sources/App/StatusItemController.swift`. It lists the shared store's provider
snapshots, regardless of which providers the user selects for the status bar.
Each header remains a button that refreshes that provider. Refresh all, Settings,
Connect Phone and Quit retain their existing actions and keyboard shortcuts.

Every header now uses `snapshot.glyph.image()`. Local model detail rows use their
decorated model cell's glyph. `ProviderGlyph` remains the only icon mapping:
Claude uses `.claude`, Codex uses `.openai`, Gemini API uses `.geminiSpark`, and
Antigravity retains its existing `.antigravity` mark. Other adapters continue
declaring their own glyph; local model brands come from the existing model mapping.

The native glyph renderer reuses the bundled assets, then the existing vector
outline if an asset is unavailable. With neither available it returns `nil`, so
the provider name remains readable without a broken placeholder. Its 16-point
square frame preserves aspect ratio and existing optical sizing. Template
rendering lets AppKit supply Light/Dark appearance colors. SVG assets and outlines
draw at the requested resolution; the existing high-resolution PNG assets are
reused without downsampling. No icons, provider definitions or dependencies were
added.

## Refresh schedule

Previously, UsageStore's usage timer fired every **60 seconds** and fetched only
while a local activity monitor saw work, after a reset, or after the **five-minute
idle interval**. Local runtime inventory was already checked every second.

The existing usage timer now runs every **10 seconds**, including idle periods.
Work on another machine can change quota even if local monitors see no activity.
Adapters may declare `minimumBackgroundRefreshInterval`; the store applies this
floor independently to each provider. It is a conservative application policy,
not a claim that the unpublished endpoints guarantee a particular polling rate.

| Source | Background interval | Reason / retrieval |
| --- | --- | --- |
| Codex profiles | 10s | Live usage API; retains persisted 429 backoff. Each read also requests profile statistics and reset credits. |
| Cursor | 10s | Live usage-summary request; credential reread picks up rotation. |
| Grok | 10s | Billing API with a borrowed local credential. |
| Kimi | 10s | Live usage API with a borrowed local credential. |
| Devin | 10s | Live GetUserStatus, rather than cached Desktop quota. |
| Ollama cloud | 10s | Live usage API. |
| Gemini API | 10s | Derived usage from local CLI files and tool databases; no new quota API exists in this adapter. |
| Claude profiles | 60s | CLI process may take 20s; unpublished OAuth endpoint is known to throttle. |
| GLM, MiniMax, OpenCode, Command Code | 60s | Existing adapters document endpoint throttling; keep their former active cadence. |
| Kiro | 60s | Each `/usage` reading launches kiro-cli, with a 20s process deadline. |
| Antigravity | 60s | Missing/restarted language servers require `ps`/`lsof` discovery and remote fallback requests. |
| GitHub Copilot | 60s | Internal quota endpoint and possible `gh auth token` process fallback. |
| DeepSeek, QianwenAI browser sessions | 60s | Console scripts make multiple requests per reading. |
| Ollama local | 1s, unchanged | Local inventory API; existing relay events update model activity and measurements immediately. |
| LM Studio local | Store checks at 1s; inventory fetched at 5s, unchanged | Existing inventory cache avoids excessive server log entries. Metrics/log callbacks continue providing more frequent activity and performance updates. |

Opening the menu immediately calls the existing Refresh all callback. Explicit
refreshes bypass background cadence floors, while preserving source caches,
access refusals, retry deadlines and in-flight protection. Startup, monitoring
startup, wake, provider enablement, authentication and relevant configuration
changes retain their immediate refresh paths. Existing activity monitor events
also request a provider refresh when work starts or ends. No additional polling
loop or provider retrieval path was introduced.

A known reset boundary also bypasses the background floor once, while retry
deadlines still apply. Countdown changes alone do not trigger a fetch.

## Caches and shared state

Claude's CLI answer lifetime and retry interval were shortened from **five minutes
to 60 seconds**. Desktop cache acceptance was shortened from **30 minutes to 60
seconds**; older entries fall through to CLI/OAuth. Failed Desktop scans are
retried after 60 seconds rather than five minutes. Desktop itself may write quota
only every five to fifteen minutes; reading that same entry more frequently cannot
make it newer. CLI and OAuth remain fallbacks and retain their existing safeguards.

Network quota requests ignore the local URLSession response cache; browser quota
scripts use `cache: 'no-store'`. Provider/server aggregation delays still apply.
Credential caches remain in place: they prevent repeated keychain prompts and
track credential changes; they do not cache quota. The quota archive supplies the
last valid reading on launch or temporary failure and does not suppress fetching.

Both the status item and open menu consume UsageStore's published snapshots.
Their Combine subscriptions use the main dispatch queue so delivery continues in
AppKit's menu tracking mode. Local model metrics and activity-monitor publications
use that queue as well, keeping the decorated model cells current while the menu
is open. Existing menu rows update as snapshots arrive, keeping
their actions and targets. Reset countdown arithmetic remains local; the existing
status bar countdown timer requests no provider data.

## Concurrency, failures and limits

The store retains its synchronous pass guard and per-provider task table. A fetch
already in flight is reused by a single-provider request and skipped by a new
background pass. A stuck fetch cannot delay unrelated providers to the 60-second
pass deadline on every tick. Pass generations prevent a late abandoned pass from
clearing a newer pass's guard. Repeated `start()` calls cannot install duplicate
timers. Provider generations still reject results after disconnection or endpoint
changes.

The store also honours reported rate-limit waits for adapters without their own
backoff and applies a 60s wait to unqualified HTTP 429 errors. Existing persisted
and source-specific backoff remains in place. Explicit refresh does not bypass a
rate-limit deadline. Transient failures preserve quota and reset timestamps,
including optional usage providers with a previous reading. Confirmed logout or
unsupported plans retain their existing history-clearing semantics. Local runtime
inventory still clears when unreachable, since loaded models cannot be assumed
to remain resident.

Automated provider tests use fixtures and fake responses. Provider aggregation
delays, server retry hints and source caches mean a 10s schedule does
not guarantee that a vendor produces new data every 10s. Conservative 60s floors
can be revisited with measured endpoint budgets. When provider/model counts change,
the open menu rebuilds its sections; ordinary figure updates retain existing items.

## Files changed and validation

- `StatusItemController.swift`: header/model images, refresh on open and live menu updates.
- `StatusItemSummary.swift`, `ProviderGlyph.swift`: one native renderer shared by menu and status bar, using existing glyph metadata.
- `UsageStore.swift`, `UsageProvider.swift`: ten-second shared schedule, adapter cadence floors, retry waits, pass lifetime protection and last-good preservation.
- `AppDelegate.swift`: deliver snapshots during menu tracking and refresh on existing activity transitions.
- `ActivityCoordinator.swift`: deliver activity events during menu tracking.
- `ClaudeOAuthProvider.swift`: shorten source caches, declare cadence and avoid HTTP response caching.
- `AntigravityProvider.swift`, `CommandCodeProvider.swift`, `GLMProvider.swift`, `GitHubCopilotProvider.swift`, `OpenCodeProvider.swift`: cadence declarations and fresh HTTP requests.
- `KiroProvider.swift`, `MiniMaxProvider.swift`, `WebSessionProvider.swift`: cadence declarations for expensive/throttled sources.
- `CursorLocalProvider.swift`, `GrokLocalProvider.swift`, `KimiProvider.swift`, `OllamaProvider.swift`, `Sites.swift`: avoid cached quota responses.
- `MenuBarRefreshTests.swift`, `ClaudeOAuthProviderTests.swift`: icon rendering/fallback/appearance, live shared-state refresh, timer cadence, coalescing, retry waits, retained readings and stale Desktop-cache regression checks.
- `UsageRefreshDeadlineTests.swift`, `StatusItemLocalRuntimeTests.swift`: protect a newer pass's guard and check local-model menu icons.
- This document: inspected architecture, provider policies and remaining freshness limits.

Validation uses the native macOS build and existing XCTest suite. Tests cover all
glyphs at 2x resolution in both appearances, native template tint, missing assets,
menu command identity, immediate refresh on open, live shared-state publication,
idle polling, per-provider scheduling, in-flight coalescing, retry deadlines,
last-good usage/reset retention, provider disconnection, and status bar visibility
settings. Tests use fake provider responses rather than fetching live accounts.

Final PR verification on 2026-09-18: `make test-ci` on macOS 27 arm64, Debug:
**1,664 tests executed, zero failures, four skipped** (three opt-in integration
checks and the opt-in native-menu capture). The native-menu capture was also
enabled in a separate **45-test run with zero failures**, covering all 24 glyphs
in Light and Dark Mode. The native build succeeded and `git diff --check` passed.
