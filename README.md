<img src="docs/icon.png" width="96" alt="Nidus's icon: five ribbons pinwheeled inside a broken ring, on an amber tile">

# Nidus

**Block the apps and websites that pull you away, for as long as you say.** A
Solanum product.

<img src="docs/popover-idle.png" width="440" alt="The Nidus popover under the menu bar: a goal field reading What are you working on?, a 25 minute length, the Social and Video categories, and a clay Start button">

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
  Between sessions it does nothing at all. During one it checks your apps and
  tabs once a second, at about 50 MB of memory and a fraction of a percent of
  one core.
- **Native.** SwiftUI, AppKit and Core Animation, with the Mac's own controls:
  a Liquid Glass popover and cards, and Settings laid out like System
  Settings. It quits apps the way the Dock does, reaches browser tabs through Apple Events, and turns Focus modes
  on and off through Shortcuts. It follows Light and Dark mode, and Reduce
  Motion stills the menu bar glyph.

## What it does

Click the glyph in the menu bar, type what you're working on, pick a length
and the categories to block, and press Start. Until the session ends:

- **Blocked apps quit the moment they open.** They're asked to quit the normal
  way, so anything unsaved gets its usual prompt. Settings can hide them
  instead.
- **Blocked websites are replaced with a quiet page** in Safari, Google Chrome
  and Opera Air, which reminds you what you're working on. When the session
  ends, every tab goes back to where it was. Firefox isn't supported: it
  offers no way to script its tabs.

  <img src="docs/block-page.png" width="480" alt="The block page: Stay with it. youtube.com is blocked until your session ends. Your goal: Write the launch post. A Snooze for 3 minutes button">
- **The menu bar glyph keeps time.** At rest it is a virus particle; when a
  session starts it becomes a brain, and fills as the session runs. Settings
  can show the minutes beside it.
- **You stay in charge.** Pause or add five minutes from the popover or the
  right-click menu, and snooze one app or site for a few minutes from its card
  or the block page.
  Or turn on strict mode, which takes snooze and pause away, and asks you to
  type "stop early" to end a session before its time.
- **A card says what happened**, at the top of your screen: what was blocked,
  a snooze about to run out, and how the session went.

  <img src="docs/card-blocked.png" width="420" alt="A card: Slack quit. Write the launch post, 25 min left. Snooze 3 min"> <img src="docs/card-finish.png" width="420" alt="A card: Session complete. 25 min focused, blocked 4 times. Did you finish Write the launch post? Not yet, Yes">
- **Breaks, Focus modes and apps to open.** Breaks can run between sessions,
  Pomodoro style. A session can open the apps you work in, and turn on Do Not
  Disturb or any other Focus mode, then off again at the end.
- **Stats.** Six months of focus as a graph, with your streaks, your longest
  session, how many goals you finished and what you blocked most. Categories
  for social media, messaging, video, news and mail are ready to use, and you
  can make your own.

<img src="docs/settings.png" width="520" alt="Nidus Settings: Block what pulls you away, with Stats, and sections for sessions and blocking">

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
  restart; macOS says so in a notification. Settings → Open at login turns
  that off.
- The first time a session reaches a browser, macOS asks whether Nidus may
  control it. Say OK, or websites in that browser won't be blocked. Settings
  → Browsers shows where each one stands.
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
