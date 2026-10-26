# Nidus — handoff from Codex to Claude Code

Sam wants Nidus beautiful, lightweight, and consistent with Solanum. Memory
use is a priority. Continue from the completed work below; do not rebuild it.

## Open this checkout

- Working checkout: `/Users/posamuel/Downloads/nidus-polish-2026-10-26`
- Branch: `codex/solanum-polish`
- Implementation commit: `c708c6b` (`Polish Solanum controls and keep session choices frozen`)
- Base: `abba697`, Nidus 0.4.2 build 91.
- Original checkout: `/Users/posamuel/Documents/Default Project/nidus`
- Local candidate: `/Users/posamuel/Downloads/nidus-polish-2026-10-26/build/Nidus.app`, 0.4.2 build 92.
- The implementation is committed locally. Nothing was pushed, installed,
  released, or merged into the original checkout. Check both checkouts'
  current state before transferring changes; preserve any newer work.

Read `docs/design-0.4.md` and `docs/codex-polish-2026-10-26.md` in this
checkout, then review `git show c708c6b`. The original request is in
`/Users/posamuel/Downloads/nidus-next-for-codex.md`.

## Completed

1. Shared searchable, grouped picker with 120 curated SF Symbols for setups
   and categories. Compact button, popover, lazy grid, no catalogue scan or
   raster cache. `NidusSymbols` centralizes shared concept symbols. Settings
   tiles use flat clay and ink through Solanum tokens.
2. Settings releases its window and hosting trees on close, retaining small
   navigation state. Capture shutdown removes its resign-key observer and
   releases the panel/view.
3. Jump to anchors on General and Blocking, including repeated jumps.
   Inline feedback for refused keyboard starts, cleared when choices change.
4. Category domain previews; explicit Suggested/Add for missing presets;
   new Shopping, Games, Sports, Finance, Forums/Q&A, and AI chat categories.
   Existing installs do not automatically gain whole categories. Default
   selection remains Social and Video. AI chat stays unselected. Version 2
   adds sites/apps to existing built-in categories once, preserving deletions.
5. Duplicate custom category merge with confirmation; requires all apps,
   sites and exceptions to be covered. Remaps/deduplicates selections, setups
   and schedules; running plans stay frozen.
6. External links, native actions and JSON starts suppress resources and
   start/end Shortcuts, including inherited Settings Shortcuts. Blocking,
   strictness, project and apps-to-open behavior remain. In-app starts retain
   their workspace. Review this deliberate automation behavior change.
7. Break length frozen at start; nil fallback retained for legacy plans.
   Archived projects filtered from fresh sequence requests.
8. Block pages that stay blocked across work/break transitions refresh text,
   goal and Snooze availability without opening the original site or adding
   a distraction count. Identical block lists are handled. Block-to-block
   exception restoration was already present; preserved with a regression test.

Main files: `NidusSymbolPicker.swift`, `NidusSymbols.swift`, `FocusSettings.swift`,
`SettingsJump.swift`, `Kit.swift`, `SettingsWindowController.swift`,
`FocusCapture.swift`, `FocusOutside.swift`, `SessionResolution.swift`,
`FocusSequences.swift`, `BrowserBlocker.swift`, `FocusController.swift`,
`FocusCategory.swift`, `FocusWidget.swift`, and `Tests/NidusTests/NextPolishTests.swift`.

## Verified

- 1,122 tests passed in 167 suites, with two build jobs and serial tests.
- Optimized app built; six App Intents actions embedded.
- Local candidate's code signature verifies.
- No new dependencies, network APIs, background services or polling timers.
- Existing `docs/*-handoff.md` files preserved.

The package-document test fixture changed from an empty `.pages` directory
(which depends on Pages' LaunchServices registration) to a system-known `.app`
package. Production file classification was not changed.

## Not verified — do these next

1. Review the diff, especially external-start side effects, merge persistence,
   identical-rule break transitions, and Settings lifetime.
2. Live memory comparison against installed 0.4.2: idle, Settings open, picker
   open, then UI closed; repeat opening/closing ten times. Verify release of
   view trees and absence of retained growth. There is NO trustworthy RAM
   benchmark yet. A subprocess aborted before a valid sample; do not quote
   its startup RSS. Desktop preview access timed out.
3. Render and inspect both appearances. Verify the symbol picker layout,
   category rows, Jump to actually scrolling, keyboard feedback, and live
   dark glass/contrast. The focused renderer was added but could not be
   exercised here:

   ```sh
   swift build --jobs 2
   .build/debug/Nidus --render-polish-surfaces /tmp/nidus-polish-renders
   ```

   It uses demo settings and a throwaway folder. It includes a Settings close
   check that prints `SETTINGS_RELEASED`. Flat renders do not prove live glass.
4. Original live checks remain: capture/Open Nidus global shortcuts and
   conflicts/relaunch; Undo End, forgotten pause, Option-click +5, Command-1
   through Command-4; Brick; Capsid task names; calendar; Plaque snapshot.
5. The icon compiler was blocked by system-service access here. The local
   candidate reuses the unchanged compiled icon from installed 0.4.2 and was
   signed again. Build normally on the interactive Mac before a future release.

## Build commands

Normal Mac:

```sh
cd /Users/posamuel/Downloads/nidus-polish-2026-10-26
swift test --no-parallel --jobs 2
NIDUS_BUILD_JOBS=2 Scripts/build-app.sh
```

Managed runner (compiler cache and nested sandbox restrictions):

```sh
CLANG_MODULE_CACHE_PATH=/tmp/nidus-polish-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nidus-polish-module-cache \
swift test --disable-sandbox --cache-path /tmp/nidus-polish-package-cache --no-parallel --jobs 2

CLANG_MODULE_CACHE_PATH=/tmp/nidus-polish-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nidus-polish-module-cache \
NIDUS_DISABLE_PACKAGE_SANDBOX=1 NIDUS_BUILD_DEBUG_INFO=none \
NIDUS_BUILD_JOBS=2 Scripts/build-app.sh
```

The script options are build-time only. Debug-info `none` avoided a restricted
dSYM step. No installation is part of these commands.

## Guardrails and deferred scope

- Keep builds at two jobs. Native SwiftUI/AppKit, small static data, lazy UI;
  no extra dependencies, daemons, polling or image caches.
- One guarded session start path; strict stays strict; plans are snapshots;
  new saved fields decode tolerantly; no network. Tests use fakes/temp folders.
- Do not push, install, release or delete branches without Sam asking.
- Preserve handoff documents and existing sample goal strings in render files.
- Sam runs the README block-page capture himself.
- Resume-note expansion, new menu-bar effects, time budgets, category sharing,
  weekly recap additions, branch cleanup and the Plaque merge were deferred.
  Propose new feature ideas before implementing them.
