> Activity V2 follow-up: new insights, local Claude Science recognition and Capsid task metadata are implemented and tested. Nidus build 11 and Capsid 0.7.3/build 36 are installed; further V2 live testing was stopped at the user’s request. See [the current Activity handoff](activity-claude-handoff.md).

> **Latest installed update (October 19, 2026):** Activity V1 and the Capsid away-status compatibility fix supersede this document's installed build identity. See [activity-claude-handoff.md](activity-claude-handoff.md) for build 10, validation and remaining access checks. The Brick setup and real-phone evidence below remain valid; the phone automation was not changed.

# Claude Code handoff: Brick automation and Nidus UI

## Current state

Authoritative checkout: `/Users/posamuel/Documents/Default Project/nidus`. Changes are uncommitted. Continue here; do not restart implementation. Starting commit was `ff24f96`. Preserve the user's sample-goal edits in NidusModel.swift and StatsRenders.swift and the droplet-cleanup work/handoff.

The user wants Nidus to **offer choosing a session when the phone is bricked**, with no automatic session start or end. They explicitly corrected the earlier fixed “Phone focus” flow: Brick must open the normal editor so they choose their goal, setup and duration. Do not reinstate a mapped setup or direct-start Brick button. They prefer Sol and Luna subagents and agent-operated setup, with only unavoidable phone/Apple confirmation steps left to them. Their normal phone flow is **open Brick, scan the physical device, then leave the app**. They want minimal iCloud use; do not enable unrelated services or Desktop & Documents sync.

The refreshed app is installed and open at `/Applications/Nidus.app`. The old “Phone focus” saved setup remains in preferences as an ordinary saved setup, but Brick no longer selects or requires it. Brick offers **Choose session**, which opens the normal composer with existing drafts intact; no session starts until the user explicitly starts one there. The companion remains enabled and connected to the original iCloud Shortcuts request file. Original **Request Mac Focus** is already imported and its iPhone-to-Mac delivery was verified. New **Sync Brick with Nidus** is built, signed, and imported on the Mac (confirmed by Shortcuts listing). The user confirmed it also appears on the iPhone. The user ran it successfully on the iPhone. Its first native result was `phone_focus_cleared`, `brickState: off`, ID `B128582-581761`, at 13:52:07 EDT on October 19. Live Nidus preferences confirm receipt and `focusing` remains false. **The iPhone personal automation is now saved, enabled, and verified through an automatic off-state delivery. The user subsequently bricked the phone and left Brick; a real on-state request and installed Nidus receipt are now verified.** After the user granted Accessibility, Codex completed setup through iPhone Mirroring. The saved automation is named **Run Sync Brick with Nidus on Close**, with **When Brick is closed**, **Run Sync Brick with Nidus**, Automation enabled, and Notify off. Screenshots and native receipt evidence are in the artifact directory.

## Automatic Brick state check

A concrete capability was found in Brick's public shortcut linked by its [official guide](https://support.getbrick.com/en/articles/11247233): `com.brickllc.brick-app.IsBrickedIntent`, displayed as **Is Brick mode enabled?**. The official shortcut feeds its output into a native If. This is an actual Brick-reported state query, not an NFC tap inferred to mean bricked. Exact source and action shapes are saved with the artifact below.

The saved phone automation is **When Brick is closed → Run Sync Brick with Nidus**, with Automation enabled and Notify off. This phone version uses Library → Automation and a trigger block in the shortcut editor; earlier bottom-tab and Run Immediately directions did not match its UI. Codex used the built-in builder, then inspected the actual trigger/action and enabled settings before returning to the saved list. [Apple defines Is Closed](https://support.apple.com/en-gb/guide/shortcuts/apde31e9638b/9.0/ios/26) as closing/switching away. [Personal automations are device-specific](https://support.apple.com/en-gb/guide/shortcuts/apd690170742/9.0/ios/26), so this phone trigger cannot be created through Mac Shortcuts sync. This is a state check after leaving Brick, not a continuous Brick state-change callback. Scheduled background activation without leaving Brick is not covered.

The signed wrapper:

- Queries the official Brick action, converts the result to string `on`/`off`, reads `brickState` from the existing request file, and writes only if the observed state differs.
- First unknown/on sends a request; first unknown/off writes a clear. This intentionally provides an initial state observation.
- On: fresh ID/timestamp, `event: phone_focus_requested`, `brickState: on`.
- Off: fresh ID/timestamp, `event: phone_focus_cleared`, `brickState: off`.
- IDs combine two independent six-digit random numbers. ISO timestamps include time and timezone. The original custom-date ID bug is avoided.
- Uses the **same** `nidus-brick.json` in iCloud Drive → Shortcuts; adds no separate state file or cloud service. Explicit `WFShowFilePicker: false`, `WFFileStorageService: iCloud Drive`, fixed path, overwrite true. A missing original file aborts before writing.
- The extra `brickState` field is a shortcut deduplication marker; Nidus's Codable receiver ignores extra keys. A manual Request Mac Focus run omits that marker, so the next state check can send an initial observation again.

Artifacts: `/Users/posamuel/Downloads/nidus-brick-auto-2026-10-19/`

- `Sync Brick with Nidus.shortcut` — signed package; SHA-256 `88820059356e9a3d2b478de4c16344269486ba8a32271bcb4c7ae8f18bda97e9`.
- `build_sync_shortcut.py`, unsigned source, `validate_sync_shortcut.py`, `simulate_sync_shortcut.py`.
- `Brick Block.public-source.unsigned.shortcut`, `Brick Block.action-shapes.json`, `FEASIBILITY.md`.

## Mac behavior and safeguards

The earlier fixed-setup Brick flow has been replaced with a choice-first flow. The card and popover say **Choose session**; the handler validates enabled/idle/freshness and matching request ID, dismisses the offer, then opens the standard popover. No session request is constructed by this action. The obsolete Settings setup picker and setup requirement in `--connect-brick-file` have been removed. Existing stored mapping is ignored, and saved setups are preserved.

Original opt-in file polling and local `nidus://brick` request path remain. Reads run about every two seconds off the main thread, capped at 4 KiB. Freshness is 120 seconds with 15 seconds future allowance; IDs are bounded ASCII. Persistent replay ledger, startup baseline, and security-scoped bookmark renewal remain. Busy requests are consumed; no queue, no automatic start, no strict-mode weakening.

New `phone_focus_cleared` events dismiss only the pending offer, even if the Mac is busy. They never end, pause, or alter a running session. Recording a clear advances the ledger floor, suppressing delayed older requests. A delayed clear older than a newer ledger entry is ignored. At equal timestamps, clear wins conservatively; second-resolution phone timestamps cannot order two transitions within one second. This favors avoiding an obsolete offer.

The explicit local `--connect-brick-file <absolute-path>` setup option remains: quit all Nidus copies first, require valid bounded JSON, then let Nidus create/verify its own bookmark before changing preferences. A helper-created bookmark failed live delivery earlier; do not reuse it. The original app-owned connection survives relaunch and worked with the new installed build. Setup launch must finish before a second Launch Services open, or single-instance handoff can skip the option.

## UI refresh

The idle popover now has a warm goal area, saved setups grouped below it, a separate session-plan area, a full-width primary action, and a compact icon/serif header. Phone offers have an amber phone emblem, explain that the user chooses the session, and offer **Choose session / Not now**. Brick settings labels were simplified. Existing keyboard focus, history navigation, custom duration, categories, projects, setups and inbox callbacks are preserved. No Return shortcut starts a session from the phone offer.

Long setup names truncate within their chips, with full accessibility/help text; the plus and sequence controls remain visible. Light/dark previews are readable; on-clay text was checked at about 5.3:1 contrast. The existing offscreen renderer does not validate live macOS glass or real clicks.

Latest source changes for this follow-up:

- `Sources/Nidus/App/FocusWidget.swift`: idle/header UI from the earlier refresh (unchanged in the choice-first follow-up).
- `Sources/Nidus/App/BrickCompanion.swift`: clear event/order handling; choice-first offer/action; no setup mapping or direct start.
- `Sources/Nidus/App/NidusApp.swift`: file connection no longer requires a saved setup.
- `Sources/Nidus/App/NidusModel.swift`: removed only obsolete demo setup mapping, preserving existing sample-goal edits.
- `Sources/Nidus/App/RenderSurfaces.swift`: bounded light/dark previews for idle, custom duration, long setups, running, and Brick offer.
- `Tests/NidusTests/BrickCompanionTests.swift`: choice callback and disabled/busy/expiry guards, plus existing clear/replay checks.
- `docs/brick-companion.md` and this handoff.

## Validation and installed build

Latest choice-first fix evidence: `/Users/posamuel/Downloads/nidus-brick-choose-2026-10-19/`. Earlier automatic shortcut and phone-flow evidence remains under `nidus-brick-auto-2026-10-19/`.

- **45 focused tests in 4 suites passed** for the choice-first correction, `nidus-brick-choose-2026-10-19/focused-tests.log`, covering Brick and saved setup behavior. New tests verify the composer callback needs no saved setup and cannot run for disabled, busy, or expired offers. The prior automatic-state implementation passed 44 tests in the earlier artifact directory. The earlier full **953 tests/139 suites** passed before this follow-up; do not claim a new full suite run.
- Release build passed with **two workers**; `release-build.log`. Existing signing certificate used; six App Intents metadata entries included.
- `git diff --check` passed.
- Signed installed bundle manifest matched the build. Version/build remain 0.4.0/9. **Latest executable SHA-256: `520141728ae53e6ad36c77c0ac117d40a1bbed1030009d962eef1ebf77fa1087`**.
- Latest backup and installation evidence: `nidus-brick-choose-2026-10-19/installation-72110f0f/`. Bundle manifest and signature verified, installed process confirmed, app opened. This supersedes the prior automatic-state build hash `357e6b3b...` and `installation-b7b92e02/`.
- Live installed choice-first UI: `brick-offer.png`, `chooser-after.png`, and `installed-chooser-probe.json` in the latest directory. A synthetic local request displayed the new **Choose session** card; clicking its observed button dismissed the prompt and opened the normal editor, with Goal focused and `focusing: false`. No session was started. An initial AX-only probe could not see floating controls; final verification used actual observed screenshots and a direct click. Phone automation and cloud file were not changed by this UI check.
- Earlier `ui-previews-final/` contains 12 actual isolated app renders. They are opaque previews, not screenshots of the live menu-bar material.
- `installed-receiver-probe.json`: installed app recorded synthetic on and clear events, ignored an older delayed request, and kept `focusing: false`. Original iCloud file contents were restored. Initial probe read the delayed on-disk preferences cache and timed out; retry used live CFPreferences and passed. Do not diagnose that cache delay as an app delivery failure.
- Shortcut static validation passed: 28 actions, 3 conditional groups, reference/path checks. **7 isolated workflow simulations passed** using temporary files. These do not validate actual native Shortcuts/Brick runtime behavior.
- First native automatic-wrapper iPhone run: `first-native-iphone-run.json` records ID `B128582-581761` at 13:52:07 EDT, `phone_focus_cleared` / `brickState: off`, live installed receipt, and no session start. This verifies the real Brick action and the initial missing-marker/file path for the off case; at that stage on-state, deduplication, and automated triggering still needed phone checks. See the subsequent automated result below.
- Actual iPhone personal automation: `iphone-automation-settings.png`, `iphone-automation-saved.png`, and `iphone-automation-verification.json`. Ordinary opening/leaving Brick while off left the request file byte-identical and focus inactive. To prove the trigger actually executed, saved the file as `request-before-automation-proof.json`, removed only its `brickState` marker, then opened Brick and returned to Shortcuts without a scan or manual shortcut run. The phone automatically wrote fresh clear/off ID `B144980-181862` at 14:13:06 EDT; live Nidus preferences recorded it, and `focusing` stayed false. The file now contains that legitimate native off report. This initially verified automatic off-state execution and receipt; the subsequent physical brick/on result is below.
- Physical Brick/on flow verified: user reported bricking the phone and leaving the app. The real iPhone wrote `phone_focus_requested`, `brickState: on`, ID `B352425-271828`, at **14:34:55 EDT on October 19**. At 14:35:19 EDT the signal was about 25 seconds old, live Nidus preferences contained its ID, and `focusing` remained false. Evidence: `physical-brick-iphone-verification.json`. This proves automatic delivery and installed receipt while bricked; the visible offer was not independently inspected during this check. Repeated-on deduplication and actual on-to-off clearing still require live phone checks.
- Earlier real iPhone test: `../nidus-brick-evidence-2026-10-19/live-iphone-verification.json` records original shortcut ID `B-977385` at 13:09:03 EDT, installed receipt, user-confirmed visible offer, and no session start.

## Finish with the user

1. Import is complete: the Mac listing contains **Sync Brick with Nidus**, and the user confirmed it is on the iPhone. Do not ask for another import.
2. First manual native iPhone run is complete and verified for initial off state (see evidence above). Do not repeat import or initialize again, and do not run it on the Mac: the Brick action is iPhone-specific.
3. Personal automation setup is complete and verified in the saved phone UI. Do not ask the user to recreate it. iPhone Mirroring control now works after their Accessibility grant. Its phone content exposes only an AXGroup, so control used observed screenshots and clicks; activate/focus the Mirroring process immediately before each interaction/capture. No further setup is required before the physical scan test.
4. Physical bricking then leaving Brick is verified through native on-state file delivery and installed receipt (14:34:55 EDT). The corrected choice-first Mac offer/action is separately verified with a synthetic local request. Do not ask the user to repeat successful setup tests. Repeated-on deduplication and an actual on-to-off clearing check remain. Reopening/leaving Brick while still bricked should write nothing and not create another offer. Unbricking/leaving should clear a pending offer without ending an active Mac session.
5. Update this handoff with the exact phone results and any remaining gap. Preserve minimal iCloud scope and two-worker build limit. Avoid another full render suite or needless rebuild; the user restarted earlier because the Mac was chugging.
