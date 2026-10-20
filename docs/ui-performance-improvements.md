# UI and performance improvements

Implemented 20 October 2026, based on `f75f07c`, on branch
`improve/ui-performance`. The app remains native SwiftUI/AppKit with no
third-party dependencies.

## Changes

| Area | Implementation |
| --- | --- |
| Countdown | A separate observable clock updates countdown/progress leaves. Session, history, access and preference changes explicitly notify the model. |
| History summaries | Stats caches by history revision, day and calendar; Activity caches project insights. Day, timezone, clock and locale notifications invalidate relevant presentation. |
| Brick | Equal statuses no longer publish repeatedly. Debounced file-presenter notifications trigger serialized reads; a tolerant 30-second recovery poll remains. Security scope, bookmark renewal, freshness and replay checks are preserved. |
| Menu-bar glyph | Ordinary progress ticks change only the fill mask and preserve existing morphs. Static header artwork and the menu font are reused. |
| Persistence | Immutable session/history/inbox/resume snapshots encode and write on a serial utility queue. New pending snapshots replace older ones; deletion shares the same ordering. Paused checkpoints skip unchanged data. |
| Save failures | Unsaved edits remain in memory. Popover and Settings show a quiet failure state with Retry. Quit drains writes and rechecks current durability; failed saves cancel quit and resume the in-memory session. |
| Browsers | Independent serialized lanes for the five supported browsers, one pending replacement per lane, bounded backoff, cancellation and per-event deadlines. A slow browser no longer occupies a global sweep lane. |
| Restoration | Pending restoration survives rapid End → Start, Pause → Resume and End → Quit. Async quit restoration has a shared five-second budget; unresponsive-browser failures are logged. |
| Activity | Adaptive text colors distinct from chart fills, meaningful labels at least 11pt, wrapping context/legend text and stacked metrics when space is tight. |
| Goal field | Browsing recent goals preserves the unfinished draft and subsequent edits. |
| Settings search | Stable row/section destinations scroll and highlight results. Covered controls are disabled and hidden from accessibility. Conditional settings lead to the enabling control or appropriate chooser. |
| Menu accessibility | Focusing, Paused, Break and Idle status remains available even when visual countdown digits are hidden. |
| Setup chips | Complete labels fit the available width; remaining items move to More while keyboard shortcuts stay available. |
| Stats accessibility | A disclosed date/value list makes contribution-graph detail available without hovering. |
| Settings lifetime | Tabs create their hosting page only when selected. Closing explicitly detaches hosted views, controllers and constraints. Lightweight navigation state remains. |
| Release hygiene | Render fixtures and demo scenarios compile only in debug builds. Release startup rejects development-only flags. |
| Login items | Registration errors are logged and surfaced; controls reflect actual registration status and permit retry. |
| Concurrency | Pure setup/project helpers are nonisolated, removing the reviewed test isolation warnings. |

## Validation

- Final debug build succeeded. No Swift source warnings were reported; SwiftPM
  emitted environment warnings about unavailable user-level caches.
- Final release build succeeded with `-debug-info-format none`. The first
  release attempt compiled and linked but its optional dSYM generation was
  denied by the execution sandbox. The release executable is 9,291,384 bytes;
  that is not a bundle size or a RAM measurement. Running it with `--demo`
  correctly rejects the development mode before initializing the app.
- **87 tests in 15 suites passed** in the focused Swift Testing run. This
  includes persistence coalescing/deletion/retry/durability, browser lane
  isolation and transition restoration, clock/cache invalidation, draft
  preservation, glyph animation, accessibility, Settings destinations and
  explicit page release.
- A broader core regression run completed **153 tests in 21 suites: 152
  passed and one failed**. The failing package-detection test,
  `aFolderIsAFolderAndAPackageIsADocument`, also fails unchanged at the
  original commit in this sandbox: a `.pages` package is classified as a
  folder after macOS sandbox-extension errors. This unrelated test and its
  production detection logic were not changed.
- Independent review checked browser restoration, persistence shutdown,
  Settings teardown, Brick observation lifecycle and release gating.
- The complete test suite compiled and began execution, but stalled after a
  sandbox extension error, as the original version had. It was stopped and is
  **inconclusive**, not a passing full-suite result.
- A final debug render attempt stalled after LaunchServices/XPC errors and
  was stopped after 25 seconds. No fresh PNGs were produced.

Focused command:

```sh
swift test --disable-sandbox --jobs 2 --filter \
  'AsyncPersistenceTests|BrowserWorkPolicyTests|BrowserWorkPoolTests|UIRefinementTests|ClockAndSummaryTests|MenuBarAccessibilityTests|GlyphRenderingTests|SettingsJumpTests|SettingsTabsTests'
```

`--disable-sandbox` controls SwiftPM's package-manifest sandbox only; it does
not remove the surrounding execution restrictions.

Release command used in this environment:

```sh
swift build -c release --disable-sandbox --jobs 2 -debug-info-format none
```

## Remaining measurement

These changes remove identified work and improve interaction behavior. No
CPU, energy or RAM reduction has been measured. A release comparison in
Instruments should cover idle with Brick on/off, a session with the popover
closed, Stats/Activity open, Settings closed after visiting its tabs, and a
slow browser during shutdown. File-provider delivery and visual layout in
both appearances still require a normal macOS app session.

Initial file loading remains synchronous to preserve startup restoration
ordering. The new asynchronous writer covers subsequent production saves.
Already-sent Apple Events cannot be recalled; an unresponsive browser can
leave tabs blocked after the restoration deadline.

Implementation was made in an isolated checkout. The original checkout,
installed app and live focus data were not changed.
