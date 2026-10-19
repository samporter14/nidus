# NIDUS Activity — Claude Code handoff

Updated October 19, 2026. Authoritative checkouts:
- Nidus: `/Users/posamuel/Documents/Default Project/nidus`
- Capsid: `/Users/posamuel/Documents/Default Project/bench`

## Activity V2: installed; further live testing stopped at user request

The user said **“Do all”** to the five follow-ups: recognize local Claude Science, share Capsid project/task names, improve insights, show seconds for short visits, and clean up test artifacts. Sol implemented/reviewed the timeline and Capsid publisher; Luna implemented presentation; the parent integrated metadata, reviewed, tested and built. No commit or push was made. Preserve pre-existing working-tree changes, including Capsid's Tailscale changes.

The user unlocked the Mac and authorized completion, then said “I think we did enough testing.” **Stop further live tests.** No V2 test session started; `focus.json` remained idle. The temporary `Nidus V2 Test` category was removed after a normal quit, preferences were backed up, and Nidus reopened idle (`final-test-cleanup.json`). Native computer control timed out opening the session category menu; this is not proof of a tracking failure or success. The new Science/Capsid collection paths have automated coverage but remain unverified in a controlled live session.

Installed and opened:
- **Nidus 0.4.0/build 11**, SHA-256 `63666347e0941de738d6ec56bdf248b8914d64cc9c4b09269ea1b1a965acbd3e`.
- **Capsid 0.7.3/build 36**, SHA-256 `be82143b5291132811c3d9b7780d242759d3c88a16ea5c0f7597e288d38ac498`.
- Both installed bundle signatures and complete file manifests verified. Backups and installation proof: `nidus-activity-v2-2026-10-19/nidus-install-d532e34e/` and `capsid-install-ea713414/` under Downloads. Capsid's local task sharing is enabled; Nidus's existing activity/name settings remain enabled.
- Three exact owned old test-history entries were backed up and removed at installation; real history preserved. The neutral Science test project/task remains; do not pursue cleanup requiring more UI testing without a new user request.

### Changes

- **Claude Science in a browser:** narrowly recognizes HTTP loopback port 8765 on expected project/task routes, with the real Science application running, selected-tab title exactly `Claude Science`, and an unchanged URL on recheck. Stores the service label only. This workflow's generic tab title still cannot expose conversation names. Never infer names from conversation text.
- **Capsid project/task names:** new default-off General setting, “Share the task I’m viewing with Nidus.” Capsid publishes the focused main window's selected project/task names to `~/Library/Application Support/Capsid/nidus-context.json`. It verifies exact project/frame routes against its own metadata; older tasks have a bounded-frequency exact-session database fallback off the main thread. File is permission-restricted and atomically replaced, refreshed every five seconds and cleared on focus loss, ineligible route, disable, or quit. Nidus accepts only version 1, current foreground PID, <=8 KiB, <=15 seconds old and <=2 seconds future. Nidus's own document-name opt-in must also be on. No conversation contents or full URLs enter the file/history. Runtime cross-app delivery is **not yet verified**; further testing was stopped at the user’s request.
- **Insights:** project totals use the session's assigned Nidus project, with session counts and most-used service. Session recaps show ordered observed intervals, context/document switches, and longest uninterrupted same-context stretch. This is foreground time, not evidence of productivity or document editing.
- **Timeline:** at most 512 segments, with explicit truncation. Old sessions have no invented timeline. Pauses, restore, missed ticks and excluded intervals break continuity; removing excluded app observations cannot create a false switch across the hole. Turning off document names redacts titles while preserving boundaries between previously distinct documents. Sample timestamps come from the session clock.
- **Short visits:** durations under a minute display seconds throughout Activity, including chart/accessibility descriptions and recaps.
- **Cleanup:** both owned blank Google Docs moved to Trash and verified there. Owned Word Alpha/Beta files moved to macOS Trash. Existing real documents were not edited. Three owned test history entries were backed up and removed. The neutral Science test project/task and any remaining test windows were left when the user stopped testing.

### Validation and evidence

Evidence directory: `/Users/posamuel/Downloads/nidus-activity-v2-2026-10-19/`.

- **Nidus: 985 tests / 143 suites passed**, two workers and serial execution (`tests.log`). Focused Activity tests: 16/16 (`activity-focused.log`). One earlier full run missed an unrelated ResumeNote 400 ms async callback; the final serial full run passed. Do not hide that intermittent failure.
- **Capsid: 1,376 tests / 176 suites passed** (`capsid-tests.log`), plus successful signed release (`capsid-build.log`).
- Ten fictional light/dark previews rendered (`previews/`). Overview-dark and recap-light inspected without visible clipping in the viewport. These are design checks, not live collection proof.
- `build-and-install-status.json` records current installed versions/hashes and prepared Capsid hash. `cleanup.json` records verified recoverable document cleanup.
- `docs/activity.md` documents V2 semantics and the Capsid file contract. Capsid README documents its opt-in setting.
- Existing Word/Google Docs live attribution proof for build 10 remains in the historical section below and `nidus-activity-2026-10-19/e2e/final-e2e-results.json`. It does not validate the new build's timeline or Capsid publisher.

### Optional future live verification — do not resume without a new request

1. Installation is complete. The old recap was dismissed and Nidus quit normally. Do not reinstall or ask to repeat already granted permissions.
2. The prepared installer completed both apps and recorded `verification.json` files. Previous app bundles, data and preferences are recoverable from the evidence directory.
3. A Capsid restart briefly interrupts its phone-access bridge. Its detached Science daemon should continue; verify normal app operation afterward. Do not stop the daemon or alter existing research tasks.
4. Run one controlled, non-strict Nidus session blocking only `nidus-e2e.invalid`, with a unique test goal and minimum one minute duration. Observe local Science in Safari, then the neutral test task in Capsid. Verify persisted Science service attribution, the exact Capsid `project · task` title, fresh matching PID/file clearing on focus loss, ordered intervals, switches and a realistic longest stretch. Inspect the live recap. Existing `open -a` foreground-test authorization persists; computer-control background clicks alone do not prove foreground time.
5. Archive the new test's evidence, remove only its owned history/category safely, close owned test windows, and remove/archive the neutral Science test project via a recoverable UI path. If its only deletion is permanent, the computer-control policy requires action-time confirmation; do not silently delete it.
6. Update this handoff with actual installed hashes, live results and any remaining limitation; update the pointer in `docs/brick-claude-handoff.md`. Brick's verified choice-first flow and the existing `focus.json` contract remain unchanged.

Known owned history IDs: `EAB8B23E-BE38-4C60-9A2E-65CD70D44BB8`, `3830852B-671B-4123-B442-86A011311B0A`, `A5D755FF-4E0F-4B9B-8C5D-EC389FFA71D4`.

Neutral Science project: `Nidus E2E Science` / `proj_7390cda2926f`; task `Nidus E2E Science Alpha` / `4c78e242-fdcd-4de1-8c9c-0618d789de69`. Its only prompt asked for “Ready” with no tools/research/files. Capsid's existing route is `bench://session?project=proj_7390cda2926f&frame=4c78e242-fdcd-4de1-8c9c-0618d789de69`.

---

## Historical V1 delivery and testing record

The following is preserved historical evidence. Its installed-version, cleanup and next-step descriptions are superseded by the V2 status above.


Updated October 19, 2026. Authoritative checkout: `/Users/posamuel/Documents/Default Project/nidus`.

## Delivered and installed

User authorized Activity V1 with beautiful charts, optional document names, installation, and a Claude handoff; then asked for Capsid interoperability. Sol implemented the core, Luna built the UI, and the parent integrated, reviewed, tested and installed. No commit or push was made.

- Installed `/Applications/Nidus.app`, version **0.4.0**, build **10**, opened and verified the new Activity tab with native UI automation.
- Executable SHA-256: `01d26b849871f2e1a9b68cae71117b8bd998deadc7a50685d4d268b59275e704`.
- Installed bundle signature verified; every file matched the release build manifest. Backup: `/Users/posamuel/Downloads/nidus-activity-2026-10-19/installation-eb4dc777/Nidus-before-activity.app`.
- Installation verification: `/Users/posamuel/Downloads/nidus-activity-2026-10-19/installation-eb4dc777/verification.json`.
- Activity and document-name preferences were enabled for this user as requested. Live UI confirmed both switches on and history enabled. New default installs keep both off.
- **Access approved and verified on October 19:** the user explicitly authorized window-title Accessibility and browser Automation access. Enabled the Nidus switch in macOS Device Control and Data Access; the installed Activity UI now confirms ‘Window-title access is allowed’. Both Safari and Google Chrome returned ‘ready for website recognition during your next session’. This confirms permission readiness, not an end-to-end document-timing session.
- No demo data was added to real history. Real controlled tests now exist in history (details below); Word/Google Docs attribution is verified, and the actual Claude Science workflow has a documented support gap. Tracking appears after a recorded session ends (minimum history duration is one minute).

## Live end-to-end results — October 19, completed

The user resumed testing and left the Mac idle. The explicitly approved `open -a` launcher established genuine foreground intervals. Sol reviewed the safe session path and Luna reviewed documentation claims. **Word and Google Docs in Chrome passed document attribution; this Mac's Claude Science workflow did not.**

Final owned session: **Nidus Verified Docs 20261019**, ID `A5D755FF-4E0F-4B9B-8C5D-EC389FFA71D4`, **311.57 focused seconds**. It blocked only `nidus-e2e.invalid`, was non-strict, and launched no apps or shortcuts automatically. Actual saved history and the exact session recap were both checked.

| Target | Recorded result | Verdict |
| --- | --- | --- |
| Word Alpha | `Nidus E2E Word Alpha`, 36.98 seconds | Pass |
| Word Beta | `Nidus E2E Word Beta`, 38.01 seconds | Pass: same-app document switch produced a separate row |
| Google Docs Alpha, Chrome | `Nidus E2E Google Alpha - Google Docs`, 32.00 seconds, service `Google Docs` | Pass |
| Google Docs Beta, Chrome | `Nidus E2E Google Beta - Google Docs`, 35.97 seconds, service `Google Docs` | Pass: same-browser document switch produced a separate row |
| Claude Science via its actual launcher | Safari, 153.06 seconds; no Science service or conversation title | Support gap, not passed |

Word also had 0.85 seconds of app-only startup time. Chrome had 0.78 seconds app-only and 4.00 seconds recognized Google Docs without a title while loading. These values are observed credited time, not precise per-switch latency measurements. Four-second probing still permits a few seconds of same-app title lag. Nidus's UI rounds short durations to minutes; the exact seconds above come from persisted data. The final title set contained exactly the four expected Word/Docs names, with no cross-app title leakage observed. This is not a complete privacy/settings/lock/sleep regression run.

### Actual Claude Science finding

`/Applications/Claude Science.app` (`com.anthropic.operon`, version `0.1.0-dev.20260630.t160235.sha2e3e6f9`) acts as a launcher for a local Safari interface at `localhost:8765` on this Mac. Launching it did not yield sustained foreground time under `com.anthropic.operon`. Native computer-control app selection repeatedly timed out, but the resulting Safari UI was accessible.

The existing Sign in button successfully entered the workspace without new credentials or a new access grant. Created neutral project **Nidus E2E Science**, submitted one harmless UI-test prompt requesting only “Ready” and no tools/research/files; the response was “Ready”. Renamed the conversation **Nidus E2E Science Alpha**. The conversation name was visibly correct inside the interface, while the actual Safari window and selected tab remained titled **Claude Science**. Its URL had `/projects/.../frames/...`, but current browser recognition only handles known public services; it intentionally does not identify arbitrary localhost pages. Consequently, Nidus recorded Safari time only.

**Do not claim conversation-name support for this workflow.** Native bundle allowlisting does not cover a separate Safari process, and even adding localhost recognition would not recover a conversation name from the static tab title. A future fix needs a narrowly scoped metadata integration or a title exposed by Science itself. Do not infer titles from conversation content or silently expand the title-only privacy contract. The separately installed Safari web app was not independently validated; its previous support statement is code-path coverage only.

### Evidence and cleanup

- Authoritative local results: `/Users/posamuel/Downloads/nidus-activity-2026-10-19/e2e/final-e2e-results.json`, including the full isolated session entry, verdicts, and cleanup checks.
- Intermediate `verified-word-alpha.json`, `verified-word-beta.json`, `verified-google-alpha.json`, `verified-google-beta.json`, and `verified-science.json` are checkpoint evidence. Native Activity title rankings and the exact session recap visibly showed all four Word/Docs titles.
- Nidus is confirmed **idle** (`focus.json` says `focusing: false`). Temporary **Nidus E2E Test** blocking category was removed; the original five categories remain. Tracking/name settings remain enabled. The Activity recap is open for review.
- Local Word Alpha/Beta documents remain in `/Users/posamuel/Downloads/nidus-activity-2026-10-19/`. Two private blank Google Docs and the neutral Science test project/conversation remain for inspection. No existing document contents were edited.
- Two earlier interrupted/control-only test sessions remain clearly named in history: `EAB8B23E-BE38-4C60-9A2E-65CD70D44BB8` and `3830852B-671B-4123-B442-86A011311B0A`. Their evidence is `foreground-control-attempt.json` and `interrupted-foreground-test.json`. They are not document-attribution proof and contribute to today's test totals.
- No application code, permissions, installed binary, Brick integration, or Capsid integration changed during this testing task. No rebuild or new install was necessary. Tests run on installed build 10.

## Validation

- **973 tests in 142 suites passed**, full suite with two build workers and serial test execution: `/Users/posamuel/Downloads/nidus-activity-2026-10-19/full-tests.log`.
- The final visual-only follow-up added a recap composition strip, adjusted chart scale wording, and used a serif recap heading. The final release build passed after that polish; core behavior is the same as the full-suite run.
- Final signed release build: `/Users/posamuel/Downloads/nidus-activity-2026-10-19/release-build.log`, two workers, existing Solanum Code Signing identity, six App Intents extracted.
- Ten isolated final previews (light/dark empty, weekly, monthly, recap, and full window): `/Users/posamuel/Downloads/nidus-activity-2026-10-19/previews/`. Weekly/light, monthly/dark, and recap/light inspected; no clipping in visible content. They are fictional previews, not live history or live collection proof.
- Live installed UI verified Activity navigation, enabled tracking/name switches, empty state, and permission controls. `focus.json` remained idle; no real session was started during installation.
- Initial compilation caught two integration type/return issues, corrected before passing builds. Initial full run also caught old toolbar expectations, an impossible foreground-time fixture, and the old blanket AX ban; tests now retain keyboard/content bans and narrowly permit opt-in title access in the three intended files.

## Entry points and controls

Activity is a first-class settings tab plus a menu-bar menu action. Today/Week/Month and previous/next ranges filter local history; project filters reuse session project IDs. Daily bars stack mutually exclusive top app/service labels plus Other and filter recaps when clicked. Whole sessions are attributed to their start day. Rankings for apps, sites, and document titles are different views of the same seconds, not additive totals. The finish card's View session activity opens the exact recorded session.

Tracking & privacy controls provide collection/name toggles, explicit permission actions, app exclusions, detailed CSV export, and a route to history deletion. Heavy aggregates/chart buckets are cached by history revision and calendar/project filters. Activity chart/recap data is never sent to Capsid.

# Nidus activity V1 — handoff draft (2026-10-19)

The build, regression tests, installation and live permission-readiness results are recorded above. Live document-timing results are recorded above; remaining boundaries are listed below.

## What V1 records

Detailed activity is opt in and only runs during recorded focus sessions. Nidus credits the foreground application at its existing one-second clock, excludes pauses, breaks, sleep and long clock gaps, and permits the user to exclude apps. A separate opt-in allows selected page or window titles. The session history and active checkpoint stay on this Mac; the explicit activity CSV export includes any names that were saved. A title can contain private information. Clearing history or disabling tracking clears the active session's detailed activity; changing title settings removes names from the active checkpoint. Previously finished history remains until cleared.

For supported browsers, Nidus sends bounded Apple Events to the running foreground browser process only. It reads window 1's selected tab URL to recognize Google Docs, Claude, or Word web pages, then, if names are enabled, reads that tab's title and confirms that the selected URL is unchanged before retaining the title. Safari uses `current tab` (`cTab`), `name` (`pnam`), and `URL` (`pURL`); Chrome-family scripting uses `active tab` (`acTa`), `title` (`pnam`), and `URL` (`URL `). It does not read page text, HTML, other tabs, full URLs into history, or document content. Browser Automation access must be allowed from an explicit Settings action; the periodic probe never prompts.

For Microsoft Word (`com.microsoft.Word`), ordinary Claude Desktop (`com.anthropic.claudefordesktop`), native Claude Science (`com.anthropic.operon`), and this Mac's Safari Claude Science web app (`com.apple.Safari.WebApp.67246384-D749-4D50-B379-1C4A27B67E88`), the optional probe reads only the focused window's Accessibility title. It requires Accessibility access, requested from Settings. Common shell and dialog titles are filtered. Word's bundled scripting dictionary also exposes `name of active document`, but V1 does not need Word Automation access. The Safari Claude Science web app is a standalone app with a local `localhost:8765` manifest; it is recognized by its bundle identity, not a `claude.ai` URL.

Probes run on a utility queue at most once every four seconds per active foreground context, one at a time, with 0.75-second per-read timeouts. Recent detail may be reused for up to five seconds. Results are discarded when the session changes, the app changes, permission/settings change, or the foreground process differs. Browser tab changes within the same app can still cause a few seconds of attribution lag. A denied permission or failed probe falls back to app time. Titles may be unavailable or generic; this view is a record of observed foreground time, not a measure of productivity.

## Capsid interoperability

Installed Capsid 0.7.2 has bundle ID `local.sam.bench`; its repository is `/Users/posamuel/Documents/Default Project/bench`. Nidus can already open it through the generic Apps to open chooser and can include or exclude it in app activity. Capsid should remain app-only in detailed tracking: its main window has the fixed hidden title `Claude Science`, and other windows can be generic Preview/Results or browser pages. Treating that Accessibility title as a Capsid document would mislabel the record.

Capsid already has a local Nidus integration. Nidus writes `~/Library/Application Support/Nidus/focus.json` and posts `local.sam.nidus.focus` through DistributedNotificationCenter when focus state changes. The file contains `version`, `focusing`, and optional Unix-time `until`; it contains no goal or activity. Capsid's `Lab/NidusFocus.swift` reads the file, verifies Nidus is running and `until` has not passed, and with its default-on hold setting delays Finished cards until focus ends. Questions and errors still appear; held finishes become a “While you focused” card, and “After My Focus Session” reminders return. No cloud sharing, Capsid modification, or new server is required for activity V1.

The lock/sleep contract mismatch was fixed in this change: `FocusFile.snapshot(session:quitting:)` writes optional `away: true` only for system lock/sleep pauses, with `focusing: false` and no `until`. Manual pause, end, break, and quit do not set away. FocusFileCompatibilityTests cover old-v1 decoding, running/system/manual/quit states, and the absence of activity fields. Capsid itself was not changed.

## Remaining live checks / boundaries

- Permission setup is complete after explicit user approval. No TCC database edits were used. Tracking and document-name switches remain on. All owned tests ended; Nidus is idle.
- Word and Google Docs in Chrome passed real named-document switching and saved recap checks. Claude Science through this Mac's localhost Safari interface is not supported for conversation names; see the concrete result and required integration boundary above. Ordinary Claude desktop, Safari Google Docs, and other browsers were not independently validated in this run.
- Capsid remains app-only because its shell's static “Claude Science” window title does not identify the active document or conversation. Its existing focus hold behavior is preserved and its away protocol is unit-tested; a live lock/sleep Capsid card check has not been performed.
- Same-named documents in the same app/service can combine. No stable document IDs or reopen links are stored. Generic/inaccessible titles are not guessed.
- Brick still offers Choose session and starts nothing automatically. Phone automation and the iCloud request file were untouched. See brick-claude-handoff.md for prior real-phone evidence; do not repeat its completed setup.
- Prior dirty edits in NidusModel.swift and StatsRenders.swift plus untracked docs/droplet-cleanup-handoff.md were preserved. Baseline diff is in the artifact folder. Do not reset them.

Implementation guide: docs/activity.md. New app files: ActivitySettings.swift, FocusActivityPage.swift, ActivityRenders.swift. New core files: FocusActivity.swift, ActivityProbe.swift, ActivityExport.swift. Integration changes: FocusController, SessionEngine, FocusHistory, NidusModel, settings routing/menu, wrapup surfaces. Test additions: ActivityTests, ActivityPresentationTests, FocusFileCompatibilityTests. Build script now defaults to two workers to protect this Mac's responsiveness.
