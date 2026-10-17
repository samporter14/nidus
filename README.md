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
- **A distraction inbox.** A thought you can't shake or a link you want later
  goes in the inbox instead of pulling you off task: press a shortcut you set
  in Settings (off until you do), or "Save a thought" in the popover, type it,
  press Return, and the session carries on. The block page has a Save for later
  button beside Snooze, which keeps the blocked address and nothing else (it
  doesn't unblock, snooze or open it, and strict sessions have it too). After a
  session the card says how many were saved, with a button to the inbox;
  nothing opens by itself. Items live in Settings → General → Inbox, where you
  open a link, finish an item or delete it. Finished items go after 30 days,
  the rest stay until you delete them, and Clear Inbox empties it. Nothing is
  fetched: no titles, icons or previews, just what you typed or the address.
- **Any length.** Pick one, or type it: "40", "1h30", "until 3:30". With
  your permission, "Until next meeting" ends a session when your next calendar
  event starts.
- **Setups.** Save what you start often, like "Deep work: 90 minutes, only
  Xcode, strict", and start it in one click from the popover or the
  right-click menu.
- **Schedules.** "Weekdays, 9 to 12" starts a session on its own, with a card
  a minute before that lets you skip it or start now.
- **Breaks, Focus modes and apps to open.** Breaks can run between sessions,
  Pomodoro style, and can [keep some things blocked](#breaks-that-keep-things-blocked).
  A session can open the apps you work in, and turn on Do Not Disturb or any
  other Focus mode, then off again at the end.
- **Sequences.** [A run of different blocks](#sequences-of-work-blocks): 40
  minutes of writing, a 10 minute break, then 25 minutes of figures, started
  in one click.
- **Stats.** Six months of focus as a graph, with your streaks, your longest
  session, how many goals you finished and what you blocked most. On Monday a
  card sums up last week. Export your history as CSV or JSON whenever you
  like. Categories for social media, messaging, video, news and mail are
  ready to use, and you can make your own.

<img src="docs/settings.png" width="420" alt="Nidus Settings on its Blocking tab, with toolbar tabs for General, Blocking, Setups, Schedules, Stats and About, the blocking choices, and the categories"> <img src="docs/stats.png" width="420" alt="The Stats tab: 2 hr 27 min this week, a 6-day streak, 76 sessions, six months of focus as a graph, and the most blocked app">

### Breaks that keep things blocked

A break blocks nothing, unless you say so. Turn breaks on in Settings →
General (Break after a session) and a **During a break** section appears: pick
the categories to keep blocked, add other apps and websites one by one, and
write a reminder to yourself ("Stretch, water"). Leave it empty and a break is
the same free time it always was.

- **While the break runs**, only what you chose is blocked. The session's own
  blocking is let go, so a page the session and the break both block is never
  put back on screen in between, and a page only the session blocked comes
  back. A tab that stays blocked is not put back until the break's blocking
  ends: when the break ends or you end it, the session starts again, or
  everything is put back.
- **The popover and the card** say what stays blocked and until when
  ("Social and Slack stay blocked until 10:40") and show the reminder. The
  block page says it is blocked until your break ends, and has no Snooze: a
  break is not a session to be let out of.
- **A session sets its own break.** A plan can carry its own break length and
  rules; one that doesn't takes Settings'. Settings' length and no rules are
  exactly the break Nidus has always had.
- **Ending a break** (Stop here, the right-click menu, a link or Shortcut)
  stops, with no session after it, and puts everything back, as ending a
  session does. Skipping starts the next session now. Quitting Nidus puts
  blocked tabs back, and a break that is still running when it opens again
  blocks them again. Break time is never counted as focus time.
- When a break ends by itself the session starts again with the same plan: its
  apps and Focus Shortcut run again, as they always did.

### Sequences of work blocks

A sequence is a list of work blocks and breaks, saved once. Settings → Setups
has a **Sequences** section: add one and it starts as a block, a break and a
block. Each work block has a goal, a length and, if you like, a setup (which
decides what it blocks and whether it is strict) and a project. Each break has
a length and what stays blocked during it: what the next block's setup says
(or Settings' break rules), nothing, or rules of its own. Add, remove and
reorder steps with the buttons on the page, and the page shows the plan as a
line ("40 min writing → 10 min break → 25 min figures") and says what stops
it from starting: it needs a work block, finite lengths, no break at the start
or end or two in a row, and setups that still exist and can start.

Start one from the popover (the list icon beside the plus), from the
right-click menu, or from its page.

- **Everything is decided when it starts.** Each block is resolved into the
  same plan a session started from that setup would have, and the run keeps
  that. Editing the sequence, a setup or Settings afterwards leaves a run
  under way alone.
- **Blocks run one after another.** A break between two blocks keeps what you
  chose blocked; a block straight after a block starts at once; the last block
  ends the run with no break after it. The usual break after a session never
  comes in a run. Each block is recorded in your history once, on its own.
- **The popover says where you are**: "Block 2 of 3 · next: 10 min break",
  and on a break, "Next: 25 min Figures".
- **Skip break** starts the next block now. **End break** ends the whole run,
  and so does ending a block that isn't strict. There is no way to skip a
  block. A strict block can't be paused, snoozed, shortened or skipped; it
  ends early only behind its phrase in the popover, which ends the run too.
- **Away.** Sleep and the lock screen pause a block as they pause any
  session. A break that ran out more than a minute ago (the Mac slept, or
  Nidus wasn't running) ends the run rather than starting a block for someone
  who may not be there. A block whose time passed while Nidus wasn't running
  is recorded as ended while away and ends the run: missed blocks are not
  replayed. Quit Nidus mid-block or mid-break and the run is where you left it
  when it opens again.

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
your session history and your inbox.

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
