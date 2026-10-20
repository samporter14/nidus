# Activity during focus

Activity is a new Settings tab and menu-bar menu item. It measures the app in front only during running focus sessions. It does not infer productivity, read document contents, or treat a quiet keyboard as absence. Session recaps are available from the finish card and the Activity session list.

## Views

Today, Week, and Month offer previous/next navigation and project filters. The daily chart stacks exclusive app/service categories (top four and Other); selecting a day filters session recaps. Daily totals group whole sessions by their start day. New sessions also retain a bounded ordered timeline for their recap. Focused time and observed time are separate; gaps remain unobserved. App, recognized-site and title lists describe different views of the same seconds and must not be added together.

App and title rankings show seconds below one minute and readable minute/hour labels for longer durations. A title is grouped with its app/service to prevent accidental cross-app merging. Different documents with the same name inside the same app/service can combine. Titles are not stable document identifiers and cannot be used to reopen documents. Earlier app-only history remains readable; detailed titles cannot be reconstructed retrospectively.

New recaps show observed intervals, known document switches, context switches, and the longest observed same-context stretch. Pauses, sleep, relaunch, excluded apps and skipped samples break continuity. The timeline retains at most 512 segments; when capped, the UI explicitly labels metrics as applying to retained observations. Older sessions have no invented timeline or retrospective switch metrics. Project insight cards summarize observed time and leading apps/services by the session's assigned Nidus project.

## Tracking and access

Product defaults are off for activity and document names. The Activity page's Tracking & privacy controls enable collection, opt into names, grant access explicitly, exclude apps, and export activity. Record sessions must also be on. Names may contain private information and are included in the local active-session checkpoint, history JSON, and explicit activity CSV export. No new cloud synchronization or network service is involved.

Browser recognition uses only the running foreground browser's selected tab. Supported browser profiles are Safari, Chrome, Opera Air, Brave and Chromium; Automation permission is requested only after a button click. Recognized sites are Google Docs document pages, Claude, supported Word web hosts, and the local Claude Science interface. Local Science recognition requires the running native launcher, HTTP loopback port 8765, an expected project/task route (or home), and the exact generic selected-tab title `Claude Science`. This generic application label is checked even with document names off, only to identify the service; it is never stored as a conversation name. Full URLs are used transiently for classification and discarded. When names are enabled, the selected URL is checked again after the title read to reject a tab-switch mismatch.

Native Word, Claude Desktop, and Claude Science use the Accessibility title of the focused window, when access is available and names are enabled. Only the title attribute is read; no content tree, screenshot, or keystrokes are recorded. Generic shell/dialog titles are ignored. An application that does not expose a meaningful title falls back to app time. Names can lag window/tab changes by a few seconds: probes run at most once every four seconds, one at a time, and cached detail expires after five seconds.

Disabling history/activity clears captured activity from the active checkpoint. Disabling names removes active checkpoint titles. Adding exclusions removes those apps from the active checkpoint. Previously finished history is retained until Clear history, except that **Remove saved names…** (Activity settings, confirmed) takes document and conversation names out of every finished session and the running one while keeping their times, apps, sites and timeline switches. Clear history also clears current activity so removed samples cannot reappear at session end. JSON export includes the new optional activity data; the old session CSV schema stays stable, and Export activity creates a separate detail CSV with spreadsheet-formula escaping.

## Capsid

Capsid (`local.sam.bench`) appears as its own app and has a separate, default-off “Share the task I’m viewing with Nidus” setting. With sharing enabled in Capsid and document names enabled in Nidus, the active Capsid project/task label can be recorded. No shell-title guessing is used.

Capsid writes `~/Library/Application Support/Capsid/nidus-context.json` only for its visible, focused main window on a matching task route. The small version-1 file contains its PID, a Unix timestamp, project name and task name. The file is owner-readable/writable, refreshed every five seconds, and removed on focus loss, ineligible pages, disabling sharing, or quit. Nidus accepts at most 8 KiB, requires the foreground PID to match, and rejects timestamps older than 15 seconds or more than two seconds in the future. It combines the bounded project/task names for display. No conversation content, URL, network call or new OS permission is required. Both toggles and app exclusions still apply.

Claude Science's separate Safari interface is recognized as a service but exposes a static tab title, so its conversation names remain unavailable there. Opening the same task through Capsid enables the explicit metadata integration. Capsid remains selectable in Apps to open and tracking exclusions.

The existing Capsid integration uses Nidus's local `focus.json` and `local.sam.nidus.focus` notification. The optional `away: true` field now covers system lock/sleep pauses, keeping Capsid's Finished cards held. A manual pause, session end, break or quit releases focus normally. No activity, document name or goal is included in that status file. The new metadata file is separate from this existing focus-status contract.

## Validation / previews

In a debug build, `--render-activity-surfaces <directory>` renders a small set of isolated light/dark Activity views with explicitly fictional data. `--demo activity-filled --open activity` is an isolated interactive demo. Neither can probe real apps or use real history. Release builds exclude these fixtures. Keep builds at two workers (`NIDUS_BUILD_JOBS`, default 2).

See `activity-claude-handoff.md` for final validation, installed build identity, and remaining live checks.
