# Nidus 0.4 — design and cross-feature rules

Nine features land together: saved workspaces, resume notes, a distraction
inbox, projects, sequences, precise website exceptions, calendar-aware
schedules, breaks with their own rules, and a focus display on Plaque. This
file is the contract they share. Where a rule here and a feature's own code
disagree, this file wins until it is changed on purpose.

## Ground rules (every feature)

- **One start path.** Every new way to start a session (a setup, a resume
  note, a sequence's first block, a delayed scheduled block) goes through
  `NidusModel.startSession(_ request: SessionRequest)`. It is the only path
  that refuses while a session or a break is on. `SessionEngine.start` and
  `FocusController.start` end a running session silently; nothing new calls
  them directly, except the engine itself starting a sequence's next block or
  a break's plan, which it already owns.
- **A plan is the snapshot.** Everything a session commits to is resolved
  into its `SessionPlan` when it starts (setup over Settings), and the plan is
  saved with the session. Editing a setup, a sequence, a project or Settings
  mid-session changes nothing about the running session or its break.
- **Strict stays strict.** No new control pauses, ends, shortens, skips or
  loosens a running strict block: not a break rule, not a sequence skip, not
  a calendar suggestion, not an exception edit, not the inbox, not Plaque.
  `SessionEngine.pause/snooze` and the strict end gate are unchanged.
- **Persistence.** New fields are optional or defaulted and decode one by
  one (`decodeTolerant`, `decodeLossy` in Core/Lossy.swift). Lists the user
  made are read with `preferenceList` (element by element). A malformed new
  field drops itself, never the session, the setup list or the history.
  New files go in `host.environment.containerDirectory` and are written with
  `.atomic`.
- **No network.** No URLSession, no page titles, favicons or previews, no
  accounts, no telemetry. `PrivacyTests` must keep passing; extend it when a
  feature adds a file or an outgoing notice.
- **No shell.** Files open with `NSWorkspace.open`, apps with
  `NSWorkspace.openApplication`, Shortcuts through `FocusShortcuts.run` (it
  passes the name as an argument, never interpolated). User text never goes
  into a command line, a script, a URL query unencoded, or HTML unescaped.
- **Tests use fakes.** Swift Testing (`import Testing`, `#expect`). Fake
  clocks (`TestClock`, `MemoryStore` in SessionEngineTests.swift),
  `FakeCalendarSource`, temporary folders. Nothing reads the real calendar,
  browser tabs, focus history, Keychain, or Nidus's real Application Support.
  Nothing starts a real session, quits an app or opens a URL.
- **UI.** Native SwiftUI/AppKit, the existing `Solanum.swift` and `Kit.swift`
  pieces. The popover stays compact: a feature shows there only when it has
  something to say (a resume note waiting, a sequence running, inbox items).
  Configuration goes in Settings, revealed progressively (off until turned
  on, details under a disclosure). Keyboard access, accessibility labels and
  both appearances for everything. No renaming, no rebranding.
- **Renders.** `swift build` then `.build/debug/Nidus --render-surfaces <dir>`
  draws every surface off-screen in Ivory and Slate with demo settings and a
  throwaway folder. Add scenarios for new surfaces in `RenderSurfaces.swift`
  and `NidusModel.runHarnessScenario`. **Add new `case`s only: do not edit
  the existing sample goal strings there or in `StatsRenders.swift`** (the
  user has uncommitted edits on those lines).

## The shared shapes (already in place)

Core/SessionPlanParts.swift: `BreakRules`, `WebsiteException`,
`WorkspaceResource`, `SequenceStepRef`, `SequenceStep`, `SequenceRun`.
Core/FocusProject.swift: `FocusProject`. On `SessionPlan`: `setupID`,
`projectID`, `projectName`, `breakLength`, `breakRules`, `websiteExceptions`,
`resources`, `isContinuation`, `sequenceStep`. On `BreakState`: `rules`. On
`SessionRecord` and `SessionEngine`: `sequence`. On `SessionEntry`:
`projectID`, `projectName`, `setupID`, `sequenceStep` (copied from the plan in
`init?(ended:)`). On `FocusCategory`: `websiteExceptions`. On
`SessionRequest`: `setupID`, `projectID`, `launchApps`, `startShortcut`,
`endShortcut`, `breakMinutes`, `breakRules`, `websiteExceptions`,
`resources`, `sequenceStep`; `startSession` copies them into the plan.

Inherit vs. none vs. a value: on `SessionRequest`, nil always means "what
Settings says" (0.3's behaviour). An explicit none is the empty value: `[]`
apps, `""` shortcut, `0` break minutes, `BreakRules()` (unrestricted).

## Feature rules

### 1. Saved workspaces (FocusSetup)
- A setup may add: apps to open, documents and folders (bookmarks), web
  pages, start/end Shortcuts, break minutes and break rules, a project, and
  website exceptions. Each override is three-state in the saved setup:
  inherit Settings / none / its own value. A setup saved by 0.3 inherits
  everything.
- **Launch once per intended transition.** On `.started`:
  apps and the start Shortcut run on every work start, including after a
  break (0.3 behaviour, and how Apple Focus is turned back on); documents,
  folders and pages open only when `!plan.isContinuation`. A restored session
  (relaunch, wake) emits no `.started` and opens nothing. The engine sets
  `isContinuation = true` on the plan it restarts after a break.
- Missing or moved files: resolve the bookmark (refresh it if stale); a file
  that can't be found is listed on one card ("2 of 3 opened; Aims.docx is
  missing") with the setup's name, and the rest still open.
- **Conflicts before starting.** A setup's web page that its own blocking
  rules would block is shown on the setup page and at start ("This page is
  blocked by Video"). The fix offered is an explicit exact exception for that
  page, added only when the person chooses it. Nothing widens silently.

### 2. Resume notes
- The finish card's goal question gains an optional "What's the next step?"
  field and an optional document or page. Saved as a `ResumeNote` (id, text,
  optional `WorkspaceResource`, goal, project id and name, the history entry
  id when one was recorded, created/dismissed dates) in
  `resume-notes.json`. Text capped at 160 characters.
- Notes are kept after incomplete sessions too ("Not yet" keeps the note).
  Editing or dismissing a note never changes the entry's `finished` answer.
- "Pick up where you left off": the idle popover shows the newest undismissed
  note (one row). Resume starts a session through `startSession` with the
  note's text as the goal and its project, and opens its resource. Refused
  while a session or break is on (the button says why, nothing is replaced).
- History off: notes are still offered (they are the person's own words, not
  automatic history), with no history entry id; the card says "Saved as a
  note. Session history is off." Clear History also clears resume notes and
  says so in its confirmation.

### 3. Distraction inbox
- `inbox.json`: items with id, text (≤ 280), optional http(s) URL, source
  (`capture` or `blockedPage`), created date, completed date.
- Capture: a configurable global shortcut (off until set) opens a small
  panel; also a popover button while a session runs. Saving never changes
  the session.
- Block page: a "Save for later" link `nidus://save?u=<encoded url>&k=<token>`
  beside Snooze. The token is random per install (`block-page-token`, 0600,
  in Nidus's folder) and written into the block page; a save link without it
  is ignored, so another web page can't fill the inbox. It saves the URL and nothing else: no snooze, no unblock, no
  navigation; the page says "Saved". Repeated sweeps or reloads of the same
  URL within 10 minutes, or an open item with the same URL, add nothing.
- Only http(s) URLs are kept (others are dropped, the text is kept). Text is
  escaped wherever shown; nothing is fetched.
- After a session: the wrap-up card says "3 saved for later" with a button
  that opens the inbox. Nothing opens by itself.
- Open, Complete, Delete per item; Clear Inbox (confirmed). Completed items
  are deleted 30 days after completion; open items stay until deleted.

### 4. Projects
- `FocusProject` (id, name, archived, created) in preferences `projects`.
  Create, rename, archive/unarchive, delete. Delete removes the project from
  the list only: history entries keep `projectID` and `projectName` (shown
  as "Name (deleted)"), setups and sequences that pointed to it start with
  no project, notes keep their text.
- Per project: focused time (from `SessionEntry.focused`, which already
  excludes pauses; breaks are never entries), sessions, recent sessions,
  unfinished goals (`finished == false`), resume notes. Through `FocusStats`.
- Start another session for the project from its page (`startSession` with
  `projectID`). The popover offers a project picker only once a project
  exists.
- Export: CSV gains a final `project` column (name from the entry); JSON
  carries the entry's fields as stored. Earlier columns are unchanged.
- History off records nothing per project; Clear History clears it.

### 5. Sequences
- Saved definitions (`FocusSequence` in preferences `sequences`): name and
  ordered steps. A work step: setup (optional), goal, minutes, project. A
  break step: minutes and break rules (inherit from the next block's setup,
  none, or its own). Editable and reorderable; at least one work step.
- Starting: resolve every step into `SequenceRun` (each work step becomes a
  full `SessionPlan` via the same resolution `startSession` uses), store it
  on the engine, start the first block through the shared start path's
  guard.
- The engine owns transitions. When a block completes: the next step is a
  break → `BreakState(plan: next work plan, rules:)`; the next is another
  work block → start it; it was the last step → the run ends with no break.
  While a run is active the plan's `breakLength` / Settings' break is never
  added on top. Each work block is recorded once in history with its
  `sequenceStep`.
- Controls: Skip break = start the next block now. End break = the run ends
  (no next block). End on a non-strict block = the run ends. A strict block
  can't be skipped or ended early except through the existing strict end
  gate, which also ends the run. There is no "skip block".
- Away: a break that ran out more than `breakGrace` ago ends the run (no
  replaying missed blocks). A block's deadline that passed while Nidus wasn't
  running records `expiredWhileAway` and the run ends. Sleep and lock pause a
  block as today.
- The popover shows "Block 2 of 3 · next: 10 min break" while a run is on.

### 6. Website exceptions
- Matching is defined once, in Core/WebsiteException+Matching.swift, on the
  same normalization as `WebsiteEntry`: lowercase host without `www.`, a
  port only when not the default, percent-decoding before comparing, path
  segments compared whole. Host boundaries are exact for exceptions (an
  exception on `youtube.com` does not cover `m.youtube.com` unless it says
  so; never a substring).
- `exact`: same host, same path, and every query parameter the exception
  names with the same value (`v=abc`); other parameters (`t=`, `si=`) are
  ignored. `subtree`: same host, path at or below the exception's.
- Block mode only. `WebsiteRule.blocks(url)` = listed and not snoozed and
  not excepted. The sweep re-reads every tab's actual URL each second, so a
  page that redirects away from an allowed URL is judged at its new address.
- The UI says exactly what an exception permits before it is saved and on
  the setup/category page ("Only youtube.com/watch?v=abc. The rest of
  youtube.com stays blocked."). Exceptions are frozen into the plan; editing
  them mid-session changes nothing until the next session. Snooze is
  unchanged and never widened by an exception.
- Limitations (README): enforcement reads tab URLs once a second through
  Apple Events; a page can show for up to a second; single-page apps that
  change content without changing the URL can't be told apart.

### 7. Calendar-aware schedules
- Per schedule, off by default: "Check my calendar first" with a buffer
  (0, 5, 10, 15 min). Calendar access is asked only from a button.
- Checked once at the heads-up before a scheduled start, and read again when
  Shorten or Delay is pressed (a suggestion is never acted on from a stale
  read). A card left alone starts the block as scheduled: the person saw the
  conflict and chose nothing. A delayed run gets its own heads-up and check.
  No polling between; no event titles are read for this or stored (only the
  start and end of the events in the way, in memory).
- A shortened or delayed run waits while the screen is locked; on unlock the
  usual late-start rule decides (it starts with at least five minutes left).
  Ordinary schedules keep 0.3's behaviour.
- A conflict (an event overlapping the block's window, or one ongoing at
  the start) offers: Shorten (end at the event's start minus the buffer),
  Delay (start at the event's end plus the buffer, keeping the end), Skip.
  An option that leaves under 10 minutes is not offered.
- Events that count: busy, accepted or tentative, not declined, not
  cancelled, not all-day, not free/transparent. Overlapping events merge.
- Access denied or unavailable: the schedule runs as before and its page
  says the calendar couldn't be checked (unknown, never "no meetings").
- A delayed start is a one-off occurrence held in the scheduler (not
  persisted across a relaunch); it obeys the existing missed-start rules
  (not while asleep/locked, not if a session or break or sequence is on), and
  it can't start twice. Times are computed in the user's calendar and time
  zone at the moment of acting, so midnight, DST and travel don't skew them.
- Never touches a running session.

### 8. Breaks with their own rules
- `BreakRules` on the plan (from the setup, else Settings' default rules,
  else none). Default: none, the 0.3 unrestricted break.
- During a break with rules, `SessionEngine.enforcement` returns a block-mode
  `Enforcement` of the rules' apps and websites; the work session's own
  rules are released. The controller moves from the session's rule to the
  break's with `restoreTabs(keepBlocked: breakRule)`, so a page blocked by
  both is never put back in between, and a page only the session blocked is
  put back.
- The break card and popover say what stays blocked ("Social and x.com stay
  blocked until 10:40") and show the reminder.
- End break / skip break / quit / cancel clean up exactly as a session end
  does. Break time is never focus time.

### 9. Plaque focus display
- Off by default. Settings > General: "Show focus on Plaque" and, under it,
  "Include goal, project and next step" (off by default).
- Nidus writes `plaque-focus.json` in its folder (format below), atomically,
  on every state change and every 5 minutes while not idle, and posts
  `local.sam.nidus.plaque-focus`. `focus.json` and `local.sam.nidus.focus`
  are unchanged. Turning sharing off deletes the file and posts the notice;
  it does not reach a reader that already has a copy, and Settings says so.
- Plaque reads it, checks it, draws one 480 × 800 page and sends it only
  when the person chooses a reader and presses Send. No sends per tick.

#### plaque-focus.json, version 1

```json
{
  "schema": "local.sam.nidus.plaque-focus",
  "version": 1,
  "revision": 42,
  "updatedAt": "2026-10-16T14:02:00Z",
  "expiresAt": "2026-10-16T14:17:00Z",
  "state": "focusing",
  "session": { "id": "6D0C0F4E-2E35-4C2B-9C8E-0A1B2C3D4E5F", "startedAt": "2026-10-16T13:45:00Z" },
  "endsAt": "2026-10-16T14:25:00Z",
  "openEnded": false,
  "pausedRemainingSeconds": null,
  "strict": false,
  "next": { "kind": "break", "startsAt": "2026-10-16T14:25:00Z", "minutes": 10 },
  "sequence": { "name": "Grant morning", "step": 1, "count": 3 },
  "text": { "goal": "Update Specific Aims", "project": "R01 renewal", "nextStep": null }
}
```

- Dates: ISO 8601 UTC, whole seconds. Consumers must ignore unknown keys.
  A missing key and `null` mean the same; Nidus leaves empty values out
  (the example above shows them as `null` only to name them).
- `state`: `idle`, `focusing`, `paused`, `break`, `finished` (a session just
  completed; kept for 15 minutes, then `idle`), `offline` (Nidus quit; a
  saved session resumes when it opens again).
- `session`: null when idle/offline. `endsAt`: the session's end (focusing,
  timed), the break's end (break), else null. `pausedRemainingSeconds`: only
  when paused. `next.kind`: `break`, `block` or `finish`; `next.minutes` the
  length of what follows when known; `next` null when nothing is planned.
  `sequence` null outside a sequence; `step` is 1-based and counts work
  blocks only (on a break, the block that comes next); `sequence.name` is
  typed text, so it is there only with text sharing on.
- `text` (and `sequence.name`): present only when the person turned on
  sharing text; else absent.
  `goal` ≤ 120 characters, `project` ≤ 60, `nextStep` ≤ 160, sequence name
  ≤ 60; the whole file stays under 4 KB.
- Freshness: `expiresAt` = `updatedAt` + 15 minutes (24 hours when idle or
  offline). A consumer past `expiresAt` shows "Last known at …", never a live
  state. A `focusing` snapshot whose `endsAt` is more than a minute past is
  shown as ended, not running.
- Ordering: a consumer keeps the newest it accepted. A snapshot with an older
  `updatedAt`, or the same `updatedAt` and a lower `revision`, is ignored.
- Golden file: `docs/plaque-focus-v1.example.json` in Nidus, copied verbatim
  into Plaque's checks. Nidus's test encodes a fixed state (a focusing block,
  step 1 of 3, text sharing on, a 10-minute break next) and its output must
  equal the file as JSON values; Plaque's check decodes it, renders it and
  sends it to a fake reader.

## Brick phone companion

- Off by default. The user optionally chooses a JSON signal file; no saved
  setup or setup mapping is required. Enabled file monitoring is an explicit exception to idle
  inactivity: Nidus reads only that selected file about every two seconds.
  Disabling it stops monitoring. No networking API or service is added;
  iCloud Drive or another file provider, when chosen, handles delivery.
- A request means an intention to focus, never verified Brick state. It
  offers Choose session and Not now only while idle. It cannot auto-start, end a
  session, unbrick a phone, or weaken strict mode.
- The same freshness and replay checks apply to the file and local
  `nidus://brick` links. Existing file contents are consumed as a baseline
  on enable, file selection, and launch. Busy requests are consumed rather
  than queued. Pending offers expire and are cleared when work begins.
- Choose session revalidates the request, dismisses it, and opens the normal
  session editor with existing drafts intact. The user chooses the goal, setup
  and duration and explicitly starts through the existing shared start path.
  Real phone/Brick detection and delivery require separate device validation.

## Who owns what (agents)

| Feature | Files it creates or owns | Shared files it edits |
|---|---|---|
| 6 Exceptions | Core/WebsiteException+Matching.swift, Tests/WebsiteExceptionTests.swift | BrowserBlocker.swift (`WebsiteRule`), FocusController (`websiteRule`), category editor UI |
| 3 Inbox | Core/FocusInbox.swift, App/FocusInboxViews.swift, Tests/InboxTests.swift | BrowserBlocker.swift (block page HTML), NidusLink/NidusLinkRouting, wrap-up card, popover |
| 7 Calendar | Tests/CalendarScheduleTests.swift | FocusSchedule, FocusScheduler, FocusCalendar, FocusSchedulesPage |
| 4+2 Projects, notes | App/FocusProjects.swift, App/ResumeNotes.swift, Tests/ProjectTests.swift, Tests/ResumeNoteTests.swift | FocusHistory (stats, export), finish card, popover, Settings tabs |
| 8+5 Breaks, sequences | App/FocusSequences.swift, Tests/SequenceTests.swift, Tests/BreakRulesTests.swift | SessionEngine, FocusController, break card, popover, Settings |
| 1 Workspaces | App/FocusWorkspace.swift, Tests/WorkspaceTests.swift | FocusSetups, FocusSetupsPage, FocusController (`.started`) |
| 9 Bridge | App/PlaqueBridge.swift, Tests/PlaqueBridgeTests.swift, docs/plaque-focus-v1.example.json | NidusModel (publish), Settings General |
