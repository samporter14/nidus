# Nidus polish — October 26, 2026

Based on `main` at `abba697` (0.4.2). Work is in the separate
`codex/solanum-polish` branch in `~/Downloads/nidus-polish-2026-10-26`.
No push, installation, release, branch deletion or Plaque merge was performed.
Existing `docs/*-handoff.md` files are preserved.

## Changes

- Categories and setups share a searchable, grouped picker of 120 curated SF
  Symbols. Its compact button opens a popover containing a lazy grid. There
  is no system catalogue scan, raster image cache or new dependency. Shared
  concept symbols live in `NidusSymbols`; Settings tiles use flat clay with
  high-contrast ink symbols, matching the Solanum tokens.
- Closing Settings releases its hosting trees and window, retaining only
  navigation state. Capture shutdown unregisters its resign-key observer and
  releases the panel and hosted view.
- Jump to now targets row anchors on General and Blocking, including
  repeated jumps. It uses a single deferred layout turn, without animation
  or a polling timer. A keyboard start that cannot proceed explains why in
  the popover, and the message clears when its choices change.
- Category rows show counts and a short domain preview. Shopping, Games,
  Sports, Finance, Forums and Q&A, and AI chat are available. Existing
  installations see missing whole categories under Suggested and explicitly
  add them; addition never selects them. The default selection stays Social
  and Video. Stack Exchange sites are excluded from default Forum rules.
- Versioned, additive updates improve Social, Messaging, Video and Mail.
  Removed categories are not recreated, and previously applied additions do
  not return after removal. Mail on iCloud and Substack Notes are path rules
  so unrelated work pages are not blocked by those additions.
- A custom category already covered by a built-in category offers Merge
  with confirmation of the full destination list. All apps, sites and
  exceptions must be preserved. Saved selections, setups and schedules
  follow the merged category; running plans stay frozen.
- External start requests clear setup documents/pages and start/end
  Shortcuts, including inherited Settings Shortcuts. In-app setup starts
  keep the full workspace. Apps-to-open behavior is retained.
- Settings' break length is frozen into each new plan. Legacy saved plans
  with nil retain their compatibility fallback. Archived projects no longer
  enter fresh sequence blocks through the popover's saved choice.
- Tabs that remain blocked across a work/break transition refresh their
  text, goal and Snooze availability without briefly loading the blocked
  site or counting another distraction. Identical block lists are handled.
  Block-to-block exception restoration was already implemented in 0.4.2;
  it is preserved and has an additional regression check.

## Verification

`swift test --no-parallel --jobs 2`: **1,122 tests passed in 167 suites**.
This includes external-start boundaries, break snapshots, block-page refresh,
unchanged-block-list exceptions, migrations, category merge eligibility,
path-specific default rules, symbol availability, Jump to state, archived
sequence projects, privacy, strict-mode behavior and idle inactivity.

The existing package-document test used a bare `.pages` directory, whose
package status depends on Pages' LaunchServices registration. Its fixture is
now a system-known `.app` package; production file classification is unchanged.

The optimized app was built locally, and App Intents metadata contains all
six existing actions. The managed environment requires writable compiler
caches and SwiftPM's nested sandbox disabled; the build scripts support an
explicit `NIDUS_DISABLE_PACKAGE_SANDBOX=1` opt-in. `NIDUS_BUILD_DEBUG_INFO=none`
avoids the environment's restricted dSYM step. These are build-time options
and add no runtime component.

The icon compiler could not reach its system services here. The local app
bundle reuses the unchanged compiled Solanum icon from the installed 0.4.2,
then is signed again. Its code signature verifies. No icon sources changed.

No new network calls, dependencies, background timers, services or polling
were introduced. Memory numbers are **not verified**: an isolated subprocess
aborted before a valid measurement, and desktop preview access timed out.
Do not treat its startup peak as a Nidus memory benchmark. Light/dark live
appearance, actual Settings deallocation and keyboard interaction still need
an interactive Mac check. No claim of a measured RAM reduction is made.

## Review on a Mac

Build with `NIDUS_BUILD_JOBS=2 Scripts/build-app.sh`. For this managed runner:

```sh
CLANG_MODULE_CACHE_PATH=/tmp/nidus-polish-module-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nidus-polish-module-cache \
NIDUS_DISABLE_PACKAGE_SANDBOX=1 NIDUS_BUILD_DEBUG_INFO=none \
NIDUS_BUILD_JOBS=2 Scripts/build-app.sh
```

The focused, throwaway-data renderer is:

```sh
.build/debug/Nidus --render-polish-surfaces /tmp/nidus-polish-renders
```

It covers the picker, category editor, suggested categories, setup editor,
refused-start feedback and a Jump to Plaque result in both appearances. It
also closes its Settings window and reports whether the controller releases
its reference. It does not start real blocking or read real focus history.

For live memory validation, compare the installed 0.4.2 and candidate with the
same data: idle; Settings open; symbol picker open; then all UI closed. Repeat
opening/closing ten times and inspect Activity Monitor for retained growth.
Use the same release build and scenarios for comparison.

The live checks in the original handoff (global shortcuts, Undo, lingering
pause, keyboard accelerators, glass, Brick, Capsid context, calendar and
Plaque delivery) remain manual. Sam's block-page README capture is untouched.
New feature ideas and unrelated branch/Plaque housekeeping were deferred.
