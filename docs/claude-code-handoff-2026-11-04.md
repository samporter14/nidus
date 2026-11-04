# Nidus 0.5.0 — recovered performance and interface polish

Sam asked to finish all six improvements from the November 4 review, plus the resting break glyph and optional botanical stamps. The prior “Improve App Design” thread failed after leaving useful uncommitted work. This checkout preserves that work and completes it. Keep Nidus lightweight, quiet, and consistent with Solanum.

## Checkout and status

| Item | Value |
| --- | --- |
| Working checkout | `/Users/posamuel/Downloads/nidus-polish-2026-11-04` |
| Branch | `codex/performance-qol-polish` |
| Reviewed base | `95f311f` — Nidus 0.5.0 |
| Implementation commit | `526d9ea79cb3470cd0873720a098849ca1f7f58c` — Reduce repeated work and polish session composition and feedback |
| Primary checkout | `/Users/posamuel/Documents/Default Project/nidus` |
| Primary checkout baseline verified | Clean `main` at `95f311f`; recheck before integration |
| Recovery checkout's `origin` | The primary checkout's local path, not GitHub |
| Full test suite | **Passed: 1,231 tests in 186 suites, 6.096 seconds, exit 0** |
| Visual checks | **Not completed: AppKit initialization blocked the render run; no PNGs were emitted or inspected** |

The implementation and regression tests are committed locally, with this handoff in a separate documentation commit. Nothing was pushed, installed, released, or merged into the primary checkout.

## Implemented behavior

### 1. Reuse history summaries and widget setup labels

`Sources/Nidus/App/PresentationCaches.swift` holds one statistics result, one botanical week, one project detail, and one project roster. The shared context includes the controller's history version, calendar day, and calendar configuration. History mutations, day changes, and calendar/time-zone changes invalidate results. Project edits invalidate the roster independently.

The cache is bounded by result slots. Visiting another project replaces the previous project detail instead of accumulating a dictionary. Settings close clears aggregates through `SettingsWindowController.swift`; model activation/deactivation also reset them. `NidusModel.swift`, `FocusProjects.swift`, and `Core/ProjectSummary.swift` use these results.

`WidgetSetupCache` retains only the four lightweight labels a widget can display. `WidgetBridge.swift` uses that projection; `Key.setups` preference changes invalidate it. Timer ticks no longer decode complete setup workspaces to discover that nothing changed. Existing widget snapshot deduplication still controls writes/reloads.

Regression coverage: `Tests/NidusTests/PresentationCacheTests.swift` checks repeated clock reads, history edits/clears, calendar changes, project replacement, roster edits, and widget projection invalidation.

### 2. Release the menu-bar popover after dismissal

`Sources/Nidus/App/FocusPopoverPresentation.swift` owns the `NSPopover` and `NSHostingController` only during a presentation. The delegate close callback clears the content controller, delegate, and stored popover. Shutdown also releases a presentation that was prepared but never shown. A close callback for an older popover cannot discard a newer presentation.

`FocusMenuBar.swift` delegates ownership to this object. Goal text, custom length, one-off end time, selected next step, and any prepared setup remain small model values. Reopening constructs fresh presentation content without discarding that draft. View-local presentation state can reset when the view tree is released.

Regression coverage: `Tests/NidusTests/PopoverLifetimeTests.swift` checks weak references, draft retention, fresh content on reopening, stale callbacks, and shutdown cleanup without displaying windows.

### 3. Save history away from the completion interaction

`Sources/Nidus/Core/HistoryFileWriter.swift` runs encoding and atomic file replacement on a serial utility queue. `FocusHistory.swift` changes its in-memory array immediately and enqueues a value snapshot, so the controller can update history version and notify completion UI without waiting for JSON encoding or disk I/O.

Scheduling retains at most the write in progress and the newest pending mutation. Pending history edits can replace one another because every write contains a complete snapshot. Clear is an ordered removal mutation, so an older queued save cannot recreate cleared history after it. Subsequent edits still write the latest state. File format and exports are unchanged; file failures are logged.

`FocusHistory.flush()` drains accepted work when the file itself must be inspected. `FocusController.stop()` flushes on shutdown, and history deinitialization provides a final drain. Session completion does not call `flush`. Existing tests that immediately reopen the file now explicitly flush first.

Regression coverage: `Tests/NidusTests/HistoryWriterTests.swift` exercises ordering/coalescing, a deliberately held write, clear followed by later edits, file output, and shutdown durability. A forced process kill before a background write finishes can still lose the pending update; no new crash-durability guarantee is claimed.

### 4. Choose another next step or turn an inbox thought into a goal

`ResumePopoverRow` in `FocusProjectViews.swift` keeps the suggested note and adds **Other next steps…**. Choosing another note changes the suggestion without dismissing any note or starting a session. `ResumeNotes.swift` orders waiting notes with the current project's notes first; notes without a project and notes from other projects remain reachable.

`FocusInboxViews.swift` adds **Use as next goal** to open inbox items. The action fills the composer and requests focus. It does not mark the inbox item complete, open its URL, or start a session. It is unavailable while a session or break is active. The compact inbox presentation shows at most five items and links to the full inbox.

### 5. Adjust a saved setup for this session

Setup chips retain one-click start. Their context menu and VoiceOver action now offer **Use as starting point…**; overflow setups expose the same action. `SetupComposer.swift` creates an explicit temporary value draft, with a “just this time” row and Cancel action.

Goal, length, categories, and project controls operate on the prepared draft. `FocusLength.swift`, `FocusProjects.swift`, `FocusWidget.swift`, and `SessionPreview.swift` read the same values as Start. Workspace resources, explicit empty app/shortcut overrides, website exceptions, strictness, mode, project, and break configuration survive composer edits. Saved presets and global defaults are not rewritten by those edits.

Switching prepared setups replaces an inherited preset goal but retains text the user actually edited. Cancel restores the pre-preparation goal. Starting consumes the temporary draft. A fixed clock deadline suppresses the prepared session's break, and accessible Start wording agrees with its preview. Unrelated external requests retain their normal defaults instead of inheriting a temporary setup.

Regression coverage for items 4 and 5: `Tests/NidusTests/ComposerFlowTests.swift` covers all setup overrides, preview agreement, custom/goal-clause lengths, preset switching, fixed deadlines, active-session guards, and inbox side effects.

### 6. Make protection feedback actionable and quieter

`ProtectionStatusUI.swift` makes the protection line clickable; the right-click menu opens the same fixes. `ProtectionFeedback.swift` follows application launches/termination, permission changes, and session events with a cancellable settling delay. It adds no polling timer. Closed installed browsers no longer produce warnings.

The fixes panel offers browser consent, the Automation settings page, blocking an unsupported browser for the current session, and retrying a refused app quit. Protection feedback is limited to active sessions; restricted breaks do not show a warning with a session-only action that cannot run.

`Core/ProtectionNoticeMemory.swift` bounds acknowledgement and recent-presentation memory to 64 keys each. Explicit acknowledgements persist through preferences. A different browser or a different permission problem is a different key. Acknowledgement quiets the interruption; it does not hide the protection gap or claim that blocking works. The persistent status continues to describe current coverage.

Regression coverage: `Tests/NidusTests/ProtectionNoticeMemoryTests.swift` and updated `ProtectionStatusTests.swift` cover acknowledgement memory and running-browser filtering. Real macOS Automation prompts still require a manual smoke check.

### 7. Give breaks a resting glyph

`Sources/Nidus/App/FocusWhimsy.swift` supplies `FocusHeaderGlyph` and a small native vector resting shape. The popover's header changes when a visible session enters a break, with one short settling transition. Reopening during a break shows the settled state immediately. Reduce Motion disables that transition. The ordinary brain image is cached once; there is no repeating animation or new timer.

### 8. Add optional seven-day botanical stamps

`Sources/Nidus/Core/FocusBotanicalWeek.swift` derives seven date/boolean/variant values from existing history. It keeps no goal text and creates no new tracking store. The stamp appears for a day with a recorded session meeting the existing minimum focus threshold; manually ended open-ended sessions count too. Answering the goal completion question does not change the stamp.

The optional row sits beside Today and uses three small vector variants. Empty days are quiet dots; a completely empty week is hidden. Day calculation uses calendar arithmetic, and a date keeps its shape as the seven-day window advances. `showsBotanicalStamps` is **off by default**, and history being off hides the row. Settings exposes the preference. The footer can stack its contents when horizontal space is tight.

Regression coverage: `Tests/NidusTests/BotanicalWeekTests.swift` covers calendar boundaries, qualifying sessions, stable variants, and bounded representation.

## Verification and limitations

- `git diff --check`: passed during implementation; rerun after the final edits.
- Full Swift test suite: **passed, 1,231 tests in 186 suites, 6.096 seconds, exit 0**, including all final source edits. Command: `CLANG_MODULE_CACHE_PATH=/tmp/nidus-integrated-clang SWIFTPM_MODULECACHE_OVERRIDE=/tmp/nidus-integrated-swift swift test --disable-sandbox --jobs 2 --no-parallel`. Log: `/tmp/nidus-polish-full-tests-serial.log`.
- `PopoverLifetimeTests`: all three passed in isolation in 0.077 seconds using `swift test --skip-build --filter PopoverLifetimeTests`. The full concurrent run's stall was not reproduced by this suite alone.
- Visual renders: **not completed**. The attempted run could not connect to `com.apple.hiservices-xpcservice` before `applicationDidFinishLaunching`; it stalled and was stopped with exit 130. It produced no PNGs in `/tmp/nidus-polish-renders`, so no visual inspection is claimed. Run the retained fixtures in a GUI-enabled environment before release.

`PerformancePolishRender.swift`, called from `NextPolishRender.swift` through the existing surface renderer, creates light/dark fixtures named `polish-botanical-week`, `polish-setup-starting-point`, `polish-other-next-steps`, and `polish-break-resting-glyph`. These use the renderer's throwaway model/preferences rather than the user's data.

The first default-cache test attempt was blocked because SwiftPM tried writing the Clang module cache outside permitted directories. The full concurrent run then stalled and was stopped. The final integrated run uses writable caches and serial tests as shown above; it passed without disabling lifecycle assertions. The isolated lifecycle suite also passed.

No before/after resident-memory benchmark has been performed. The change removes repeated summary/decoding work and releases ownership of dismissed presentation trees; it does not establish a particular MB saving. No unsupported CPU percentage claim should be made either.

## Integrating safely into the primary checkout

First read the final commit field above and inspect both checkouts. Preserve any unrelated working-tree changes, including changes made after this handoff. Do not reset, clean, or blindly copy directories. Do not run `git push origin` from the recovery checkout assuming that means GitHub: its origin is the primary local repository.

Fetch the committed branch into the primary repository:

```sh
git -C '/Users/posamuel/Documents/Default Project/nidus' status --short
git -C '/Users/posamuel/Documents/Default Project/nidus' log -5 --oneline
git -C '/Users/posamuel/Downloads/nidus-polish-2026-11-04' status --short
git -C '/Users/posamuel/Documents/Default Project/nidus' fetch '/Users/posamuel/Downloads/nidus-polish-2026-11-04' codex/performance-qol-polish
NIDUS_POLISH_COMMIT="$(git -C '/Users/posamuel/Documents/Default Project/nidus' rev-parse FETCH_HEAD)"
```

Create an integration worktree from the primary checkout's current committed `HEAD` so the primary working directory and any uncommitted edits stay intact. The branch/path below are proposed names; if either already exists, inspect and reuse the appropriate worktree or choose a new name, never overwrite it.

```sh
git -C '/Users/posamuel/Documents/Default Project/nidus' worktree add -b integrate/nidus-polish-2026-11-04 '/Users/posamuel/Downloads/nidus-polish-integration-2026-11-04' HEAD
git -C '/Users/posamuel/Downloads/nidus-polish-integration-2026-11-04' merge --no-ff "$NIDUS_POLISH_COMMIT"
```

Run those blocks in the same shell. Before merging, inspect the fetched history and confirm it includes the implementation commit recorded above; the branch tip may be a later documentation-only commit containing this handoff. Fetching from the recovery checkout does not create a local branch automatically; the resolved commit makes the integration target explicit.

Review the merged diff, resolve conflicts against any newer primary work, and run the suite and visual checks in the integration checkout. Read `Scripts/build-app.sh` before creating a candidate; do not overwrite an installed app or publish a release as an incidental validation step. After verification, integrate the reviewed branch through the project's normal workflow. Keep the recovery checkout until the work is safely committed and integrated.
