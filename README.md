<img src="docs/icon.png" width="96" alt="Nidus's icon: five ribbons pinwheeled inside a broken ring, on an amber tile">

# Nidus

**Block the apps and websites that pull you away, for as long as you say.** A
Solanum product.

<img src="docs/popover-idle.png" width="440" alt="The Nidus popover under the menu bar: a goal field reading What are you working on?, three setups (Deep work, Writing, Reading), a 25 minute length, the Social and Video categories, a clay Start button, and Today 1 hr 10 min, 6-day streak">

**Install in one line**: paste into Terminal (Apple silicon, macOS 27):

```sh
curl -fsSL https://raw.githubusercontent.com/samporter14/nidus/main/install.sh | zsh
```

Or [download Nidus.zip](https://github.com/samporter14/nidus/releases/latest/download/Nidus.zip); see [Install](#install).

A *nidus* is the place where something takes hold and grows.

## Why Nidus

- **Private.** Nidus collects nothing: no account, no analytics, no server.
  It never connects to the internet, and a test in this repository fails if
  its code ever reaches for the network. What it keeps stays on your
  Mac, and Settings can stop the history or clear it.
- **Light.** A menu bar app in Swift, with no Electron and no web views.
  Between sessions it does nothing at all, except keep one timer for the next
  schedule if you've made one. During a session it checks your apps and tabs
  once a second, at about 50 MB of memory and a fraction of a percent of one
  core.
- **Native.** SwiftUI, AppKit and Core Animation, with the Mac's own controls:
  a Liquid Glass popover and cards, and Settings in toolbar tabs like any
  Mac app's. It quits apps the way the Dock does, reaches browser tabs through Apple Events, and turns Focus modes
  on and off through Shortcuts. It follows Light and Dark mode, and Reduce
  Motion stills the menu bar glyph.

## What it does

Click the glyph in the menu bar, type what you're working on, pick a length
and the categories to block, and press Start. Until the session ends:

- **Blocked apps quit the moment they open.** They're asked to quit the normal
  way, so anything unsaved gets its usual prompt. Settings can hide them
  instead.
- **Blocked websites are replaced with a quiet page** in Safari, Google
  Chrome, Brave, Chromium and Opera Air, which reminds you what you're working
  on. When the session ends, or you quit Nidus, every tab goes back to where
  it was. A website
  can be a whole site (`youtube.com`, subdomains included) or just part of one
  (`youtube.com/shorts`, `reddit.com/r/all`). Firefox isn't supported: it
  offers no way to script its tabs.

  <img src="docs/block-page.png" width="480" alt="The block page: Stay with it. youtube.com is blocked until your session ends. Your goal: Write the launch post. A Snooze for 3 minutes button">
- **The menu bar glyph keeps time.** At rest it is a virus particle; when a
  session starts it becomes a brain, and fills as the session runs. Settings
  can show the minutes beside it.
- **You stay in charge.** Pause or add five minutes from the popover or the
  right-click menu, and snooze one app or site for a few minutes from its card
  or the block page.
  Settings can make Snooze wait 10 or 30 seconds first, to get you past the
  impulse. Or turn on strict mode, which takes snooze and pause away, and asks
  you to type "stop early" to end a session before its time.

  <img src="docs/popover-running.png" width="440" alt="The popover during a session: Write the launch post, until 9:37 PM, blocked 2 times, 25:00 left, with pause, +5 and stop buttons">
- **A card says what happened**, at the top of your screen: what was blocked,
  a snooze about to run out, and how the session went.

  <img src="docs/card-blocked.png" width="420" alt="A card: Slack quit. Write the launch post, 25 min left. Snooze 3 min"> <img src="docs/card-finish.png" width="420" alt="A card: Session complete. 25 min focused, blocked 4 times. Did you finish Write the launch post? Not yet, Yes">
- **Any length.** Pick one, or type it: "40", "1h30", "until 3:30". With
  your permission, "Until next meeting" ends a session when your next calendar
  event starts.
- **Setups.** Save what you start often, like "Deep work: 90 minutes, only
  Xcode, strict", and start it in one click from the popover or the
  right-click menu.
- **Schedules.** "Weekdays, 9 to 12" starts a session on its own, with a card
  a minute before that lets you skip it or start now.
- **Breaks, Focus modes and apps to open.** Breaks can run between sessions,
  Pomodoro style. A session can open the apps you work in, and turn on Do Not
  Disturb or any other Focus mode, then off again at the end.
- **Projects.** Name what your sessions are for ("R01 renewal", "Lab
  notebook") under Stats in Settings. Once you have one, the popover offers a
  small project menu, and the project you pick counts the next session toward
  it (it stays picked, like the categories, until you change it). Each
  project has a page with the time you focused on it, its sessions, the goals
  you answered "Not yet" to and haven't finished since, its resume notes, and
  Start a session. Rename, archive or delete a project whenever you like:
  your history is never rewritten, so past sessions keep the name they had,
  and a deleted project reads "Name (deleted)" in the list.
- **Pick up where you left off.** After you answer "Did you finish?" on the
  card, you can type what the next step is (up to 160 characters) and attach
  a document, a folder or a web page to open with it. Both are optional, and
  "Not yet" keeps the note just as "Yes" does. The newest note waiting shows
  as one row at the top of the popover: Resume starts a session with the step
  as its goal, and opens its link, on that click and no other; Dismiss puts it
  away. Resume never replaces a session or break that is on, and says why it
  can't.
- **Stats.** Six months of focus as a graph, with your streaks, your longest
  session, how many goals you finished and what you blocked most. On Monday a
  card sums up last week. Export your history as CSV or JSON whenever you
  like (the CSV ends with a `project` column). Categories for social media,
  messaging, video, news and mail are ready to use, and you can make your
  own.

<img src="docs/settings.png" width="420" alt="Nidus Settings on its Blocking tab, with toolbar tabs for General, Blocking, Setups, Schedules, Stats and About, the blocking choices, and the categories"> <img src="docs/stats.png" width="420" alt="The Stats tab: 2 hr 27 min this week, a 6-day streak, 76 sessions, six months of focus as a graph, and the most blocked app">

## What projects and notes keep

- **Projects** are a short list in Nidus's settings: a name, whether it is
  archived, and a stable id. A project's time, sessions and unfinished goals
  are worked out from your history each time its page opens; nothing about
  them is stored separately.
- **Resume notes** are in `resume-notes.json` beside your history, on this
  Mac only. A note holds the step, the goal and project it followed, the
  history entry it followed when there is one, its link (a bookmark to a file
  or folder, or the web address you typed) and when it was made or dismissed.
  Nothing is fetched from a link: no title, icon or preview, ever.
- **Sessions not recorded.** With "Record sessions" off, no session is
  counted toward a project. Notes are still offered, because they are your own
  words rather than history; the card says "Saved as a note. Session history
  is off." and the note has no history entry.
- **Editing a note never edits history.** Dismissing, changing or removing a
  note leaves every session, and its "Did you finish?" answer, as it was.
- **Clear History** removes the sessions, the stats and each project's numbers
  that come from them, your recent goals, and your resume notes. Your
  projects themselves stay; delete one on its page.

### Letting one page through

A blocked site can have exceptions: one research video while the rest of
YouTube stays blocked. In Settings, open a category with websites and add an
address under Exceptions. Paste it, choose **Only this page** or **This page
and below**, and Nidus writes out what it will let through before you add it.

- **Only this page** is that host, that path and nothing under it. A query
  that names the page counts: `youtube.com/watch?v=abc` lets that video
  through, with or without `&t=30s`, and not `v=xyz`. Tracking and position
  parameters (`utm_*`, `si`, `t`, `fbclid` and the like) are left out when
  you paste an address, and the preview says which.
- **This page and below** is a path and everything under it on that host. The
  query isn't used, and the preview warns when a pasted address had one.
- An exception covers exactly the host you wrote (and its `www.`): one for
  `youtube.com` does not cover `m.youtube.com`, and a page whose address
  carries a login is never let through. Paths and query values keep their
  case. Exceptions are for block lists only; an allow list already says what
  is let through.
- A running session keeps the exceptions it started with, strict or not.
  Changes to a category apply to the next session. Snooze works as before and
  an exception never widens it.

What this can't do. Nidus reads each tab's address about once a second,
through Apple Events, so a page can show for up to a second before it is
replaced, and a tab that moves from an allowed page to a blocked one is
caught at the next look (an allowed address is never remembered). Sites that
change what they show without changing the address, like a single-page app
that keeps its page after the `#` or in a script, can't be told apart, so an
exception for one of their pages covers all of them. It works in the browsers
listed above and nowhere else.

## Start it from anywhere

**Shortcuts.** Nidus adds Start Focus (with a setup, if you like), Add Focus
Time, Get Focus Status, End Focus and Toggle Focus to the Shortcuts app. For a
keyboard shortcut, make a shortcut that runs Start Focus or Toggle Focus and
give it a key in its details.

**Links.** Any app, script or launcher can open these:

| Link | Does |
| --- | --- |
| `nidus://start` | Starts a session with the popover's choices |
| `nidus://start?goal=Write&minutes=45&categories=social,video` | Starts one with these. Also `mode=allow`, `strict=1`, and `preset=Deep%20work` for a setup |
| `nidus://toggle` | Ends a session, or starts the last one again |
| `nidus://end` | Ends a session |
| `nidus://popover` | Opens the popover |

A strict session can't be ended by a link or a shortcut, only from the menu
bar, behind its phrase. Right-click a setup in the popover and choose Copy
Launch Link for a link that starts just that setup.

**Launchers and assistants.** Raycast Quicklinks are ready to import from
[integrations/raycast](integrations/raycast), and an optional skill in
[integrations/assistant-skill](integrations/assistant-skill/nidus-focus) lets
an assistant on your Mac start a setup, add time or say how long is left,
through a one-step shortcut. [docs/automation.md](docs/automation.md) has the
details, including Alfred and BetterTouchTool.

## Works with Bench

While a session runs, Nidus writes `focus.json` in its folder (whether a
focus session is on and until when, never your goal or what's blocked) and
says so on this Mac with the local notification `local.sam.nidus.focus`.
[Bench](https://github.com/samporter14/bench) uses it to hold "Finished"
cards until the session ends. Nothing leaves your Mac.

## Install

You need a Mac with Apple silicon (M1 or later) on macOS 27.

### Easiest: one line in Terminal

```sh
curl -fsSL https://raw.githubusercontent.com/samporter14/nidus/main/install.sh | zsh
```

It downloads the latest Nidus from this page's releases, puts it in
Applications (quitting and replacing an older one), and opens it. **Run the
same line again to update.** macOS doesn't show its "can't verify" warning for
apps installed this way, because it only flags apps downloaded through a web
browser. You're trusting this page instead, so [install.sh](install.sh) is
short enough to read first.

### Or download it

1. [Download Nidus.zip](https://github.com/samporter14/nidus/releases/latest/download/Nidus.zip)
   and open it.
2. Drag **Nidus** into your **Applications** folder, and open it from there.
3. The first time, macOS blocks it because it isn't from the App Store or a
   registered developer. Click **Done**, then go to **System Settings →
   Privacy & Security**, scroll down, and click **Open Anyway** next to Nidus.

### The first time

- Nidus lives in the menu bar; it has no Dock icon. Click the glyph to start,
  or right-click it for a short menu with Stats, Settings and Quit.
- It adds itself to your login items once, so a session carries on after a
  restart; macOS says so in a notification. Settings → General → Open at
  login turns that off.
- The first time a session reaches a browser, macOS asks whether Nidus may
  control it. Say OK, or websites in that browser won't be blocked. Settings
  → Blocking → Browsers shows where each one stands.
- "Until next meeting" asks for Calendar access the first time you choose
  it. Nidus reads your calendar on this Mac for the time of your next event,
  and nothing else.
- If you used Nidus as a droplet in Droppy, remove it there, so two copies
  don't block the same things twice.

## Uninstall

Quit Nidus (right-click the glyph, then Quit Nidus), delete it from
Applications, and delete `~/Library/Application Support/Nidus`, which holds
your session history.

## Build it yourself

With Xcode 27 installed:

```sh
Scripts/build-app.sh --open
```

That builds `build/Nidus.app`, ad-hoc signed. `swift test` runs the blocking
engine's tests. `Nidus --render-surfaces <folder>` draws the popover, the
cards and Settings to PNGs in both themes, off-screen, with a sample session
that blocks nothing.

## Credits

Made by [Sam](https://github.com/samporter14). Nidus began as a droplet for
[Droppy](https://getdroppy.app). MIT licensed; see [LICENSE](LICENSE).
