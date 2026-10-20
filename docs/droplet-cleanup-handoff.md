# NIDUS: standalone app cleanup — Claude Code handoff

Date: October 19, 2026 (America/Detroit).

The user authorized fixing the residual Droppy/droplet code identified in a read-only review and requested this handoff to keep Claude Code informed. Implementation is complete in the existing checkout. Review the changes already made before doing further work.

## Checkout and existing work

- Repository: `/Users/posamuel/Documents/Default Project/nidus`
- Branch: `main`
- Starting HEAD: `5cfba075fa6d6264681dd9dc61f50e419f912104`
- Changes remain uncommitted. No commit, push, or release publication was performed.
- The checkout already had user edits in `Sources/Nidus/App/NidusModel.swift` and `Sources/Nidus/App/StatsRenders.swift`. These change sample goals to “Update Specific Aims” and “Revise Figure 3”. They are preserved. `StatsRenders.swift` is byte-for-byte identical to its pre-cleanup working copy; only the intended cleanup changed `NidusModel.swift`.
- Read `docs/design-0.4.md` for the existing feature contracts. In particular, preserve the sample goal edits, the shared start path, strict-mode protections, privacy rules, and stored-session compatibility.

## Implemented changes

1. **Remove the old host blocking exemption.** `Core/AppBlocker.swift` no longer permanently exempts `iordv.Droppy` and `iordv.DroppyPlayground`. They follow ordinary block/allow rules. Nidus's own process and the existing system-app protections remain exempt.
2. **Simplify card requests.** `App/Kit.swift` now defines `HUDRequest(id:duration:accessibilityLabel:content:)`. Thirteen call sites use one content builder. Removed the unused compact builders, `FocusHUDStrip`, `DroppyLiveActivityMetrics`, priority, expansion flags, supplied heights, and the obsolete `FocusWrapUpCard.noteHeight`. `HUDPresenter` continues to measure content and replace the visible card on a new request. Existing fallback text variants, callbacks, accessibility announcements, hover/typing retention, dismissal, and remeasurement remain intact.
3. **Simplify the popover.** `FocusWidget` no longer accepts `ShelfWidgetContext`. Removed unreachable compact idle/running/break layouts and zero-inset context padding. `NidusPopover` continues to render the existing full layout at 440 points.
4. **Use Nidus UI names.** `DroppySpacing` → `NidusSpacing`; `DroppyTransition` → `NidusTransition`; `Droplet…` settings components → `Nidus…`; `AdaptiveColors.notchSurface…` → `AdaptiveColors.surface…`. Updated call sites mechanically without changing the token values or controls.
5. **Remove obsolete host and block-page plumbing.** Removed the always-true `NidusHost.isGranted(.menuBar)` check and unused `Environment.isHarness`. The menu bar is created directly. Removed `NidusModel.id`, the `dropletID` arguments/properties, and the ineffective `{{DROPLET}}` replacement. The block page remains at the same path and uses the same `nidus://snooze` and token-protected `nidus://save` links.
6. **Refresh wording and tests.** About now says “Made by Sam. MIT licensed.” README credits match. Updated obsolete comments and the privacy scanner's `dropletSources`/test names to app terminology. The block-page installation test checks that its actual token placeholder is resolved.

The cleanup changes 51 existing files; most are mechanical UI name substitutions. The broader working-tree diff also includes the pre-existing sample edits.

## Intentional remaining references

- README migration warning: uninstall the previous droplet from Droppy to prevent duplicate blocking.
- `BlockingRulesTests`: the two former host bundle IDs are regression inputs.
- `NidusLinkTests`: `droppy://end` is explicitly rejected.
- `harnessScenario`, `runHarnessScenario`, and the test `Harness` remain useful demo/render/test mechanisms. They are independent of Droppy. Isolated render mode still uses separate demo preferences and temporary data with live enforcement disabled.

The app source contains no Droppy/Droplet/ShelfWidgetContext/FocusHUDStrip APIs or exemptions. Persistence paths, saved session schemas, `focus.json`, the Bench notification, Plaque sharing, deep links, App Intents, and strict-mode behavior retain their existing contracts.

## Validation

- Before cleanup: **943 tests across 138 suites passed**.
- After cleanup: **944 tests across 138 suites passed**. The new parameterized regression covers both former host apps in explicit-block, unlisted-block, empty-allow, and explicit-allow configurations, without operating real applications.
- Build command: `Scripts/build-app.sh` completed successfully. The resulting `build/Nidus.app` passes `codesign --verify --deep --strict --verbose=2`.
- Build version remains `0.4.0` / `9`; this is a local build, not a new published release.
- `git diff --check` passes.
- Existing Swift actor-isolation warnings around `isVisible(projects:)` and `FocusSetupsBar.split` occur in both baseline and updated test builds. They are outside this cleanup.
- Visual comparison: **292 PNGs before and 292 after**, covering both themes. **250 are pixel-identical**; the remaining 42 have localized differences. No image dimensions changed and no requested surfaces are missing. Representative changed surfaces were inspected: clock/meeting text, temporary sample workspace paths, and the intended About credit. Dynamic sample data prevents complete pixel equality. Full measurements are in `visual-comparison.json` beside the Downloads copy of this handoff.

Automated tests and renders used the project's isolated mechanisms. After the user explicitly authorized installation, the updated app was installed and opened as described below. Its live popover was verified in the “New session” state; no new focus session was started. Live browser enforcement, calendar access, real Shortcuts, and login-item changes were not exercised.

## Artifacts and review

Evidence directory: `/Users/posamuel/Downloads/nidus-droplet-cleanup-2026-10-19/`

- `cleanup-only.patch`: implementation diff against the initial working tree, excluding the user's existing edits.
- `pre-existing-edits.patch`: the user's edits as found before cleanup.
- `before/`: the relevant source/test snapshots before cleanup.
- `baseline-tests.log`, `cleanup-tests.log`, `build-app.log`.
- `renders-before/`, `renders-after/`, render logs, and `visual-comparison.json`.
- Built app: `/Users/posamuel/Documents/Default Project/nidus/build/Nidus.app`.
- `installation-verification.json`: installed bundle hash, process identity, signature and UI verification.
- `Nidus-before-install.zip`: validated rollback archive of the previously installed app.

Use the checkout's current files for any follow-up. The `candidate/` folder and preparation scripts in the evidence directory are implementation intermediates, not another checkout to maintain or scripts to rerun.

For follow-up work, inspect the cleanup-only patch and current diff first. The app is already installed and open. Broader live enforcement and integration tests remain separate from the automated checks and launch verification above.

## Installation and launch completed

The user explicitly requested installation and opening the updated app. Completed October 19, 2026 at 10:55 AM EDT.

- Installed location: `/Applications/Nidus.app`, version **0.4.0**, build **9**.
- Saved and archive-tested the previous installed bundle as `/Users/posamuel/Downloads/nidus-droplet-cleanup-2026-10-19/Nidus-before-install.zip`.
- Asked the previous process to quit normally; it exited. No force termination was used.
- Verified the staged and installed bundles match every file of the verified release build and pass strict code-signature validation.
- Confirmed one running Nidus process from `/Applications/Nidus.app/Contents/MacOS/Nidus` (PID 87992 at verification).
- Opened the popover and visibly confirmed “New session”, Goal, Length, Blocked categories, and Start.
- Installed executable SHA-256: `9c1a8a29639987c045621f60d0bdd7b6780c17bdac51eaba4fbe036ea35fbefd`. The version number was not incremented, so use this hash to identify this cleanup build.
- No source implementation changes were made during installation; the working changes remain uncommitted.
