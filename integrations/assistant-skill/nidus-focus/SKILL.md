---
name: nidus-focus
description: Start, extend, end or check a Nidus focus session on the user's Mac. Use when the user asks to start focusing or start a saved Nidus setup ("start my Writing setup for 45 minutes"), to add focus time, to ask how much focus time is left, or to end a focus session. Needs Nidus and its "Nidus Command" shortcut on the connected Mac.
---

# Nidus focus sessions

Nidus is a Mac app that blocks distracting apps and websites for a set time.
Everything here goes through `scripts/nidus-focus`, which asks Nidus itself
and prints Nidus's answer as one JSON object. Nidus applies its own rules; you
only say what the user asked for.

## Commands

Run the script from this skill's folder. Put every value in single quotes.

| The user says | Run |
| --- | --- |
| "How much time is left?", "Am I focusing?" | `scripts/nidus-focus status` |
| "Start my focus session" | `scripts/nidus-focus start --id '<new id>'` |
| "Start my Writing setup for 45 minutes" | `scripts/nidus-focus start --setup 'Writing' --minutes 45 --id '<new id>'` |
| "Focus on the paper for an hour" | `scripts/nidus-focus start --goal 'The paper' --minutes 60 --id '<new id>'` |
| "Add 15 minutes" | `scripts/nidus-focus add 15 --id '<new id>'` |
| "End my focus session" | `scripts/nidus-focus end --id '<new id>'` |
| Which setups exist | `scripts/nidus-focus setups` |

- **Ids.** For `start`, `add` and `end`, make a new id once per request (run
  `uuidgen`) and pass it with `--id`. If you retry that same request, use the
  same id, so Nidus answers the retry instead of doing it twice (it remembers
  for ten minutes). Never reuse an id for a different request.
- **Goals.** If the goal contains a single quote, or is long, write it to a
  file and pass `--goal-file <path>` instead of `--goal`.
- **Status only reads.** Use it for any question. It never starts, ends,
  pauses or changes a session.

## Rules

- **"Start my focus session" with nothing else:** run `start` with no setup,
  goal or minutes. Nidus uses the user's current choices, or the default setup
  if the user configured one (see below). Name a setup only when the user does.
- **Pass only what the user said.** Don't choose categories, strict mode or a
  length they didn't ask for.
- **Use the exact name or id** when the user names a setup you're unsure of.
  Run `setups` first, then pass that name or id. If the setup isn't there, say
  so and list the ones that are; don't start something else instead.
- **There's no toggle.** Never end a session unless the user asks to end it.
- **After a timeout or an error with no JSON answer**, run `status` before
  anything else. Retry a start, add or end only if status shows it didn't
  happen, and reuse the request's id when you do.

## Reading the answer

The answer has `ok`, `outcome`, `message` and usually `status`, whose
`sentence` says where things stand. On success, tell the user `message`,
e.g. "Started Writing for 45 minutes." or "Added 15 minutes. You have 33
minutes left."

| `outcome` | What to tell the user |
| --- | --- |
| `busy` | A session or break is already on, and nothing new started. Give `status.sentence`. |
| `refusedStrict` | It's a strict session, which can only be ended from the Nidus menu bar. |
| `setupNotFound`, `setupAmbiguous` | That setup isn't in Nidus, or more than one has the name. Offer the list from `setups`. |
| `openEnded`, `onBreak`, `atMaximum` | Say `message`; no time was added. |
| `nothingRunning` | Focus isn't on, so there was nothing to add to or end. |
| `idReused` | That id was used for a different request. Make a new id and send it once. |
| `nothingToBlock` | The chosen categories are empty. The user can add apps or websites in Nidus. |
| `notReady` | Nidus isn't running or is still starting. Suggest opening it. |
| `wrapperMissing` | The "Nidus Command" shortcut isn't set up. Point to Nidus's docs/automation.md. |
| `shortcutFailed`, `unavailable`, `unexpectedAnswer` | Nidus couldn't be reached. Say so briefly. Don't claim anything happened. |

- **Unblocked browsers.** If `status.browsersNeedingAccess` lists browsers,
  say that websites in them aren't blocked until the user lets Nidus control
  them (Nidus Settings → Blocking → Browsers). The list
  fills in a moment after a start, so an empty list in the start's own answer
  means "not checked yet". Check `status` a few seconds later before saying
  websites are blocked.
- **Never report success without** `"ok": true`. A shortcut finishing isn't
  proof that a session started.

## Setup, once, on the Mac

1. Install Nidus, version 0.3 or later.
2. In the Shortcuts app, make a shortcut named exactly **Nidus Command** with
   three actions:
   1. **Get Text from Input** (Shortcut Input)
   2. **Run Nidus Command** (Nidus), with its Request set to that Text
   3. **Stop and Output**, with the Result
3. Run `scripts/nidus-focus check`, then `scripts/nidus-focus status`.
4. Optional default setup: put a setup's name or id on the first line of a
   file named `default-setup` in this folder.

A dot reaches this skill only through a connected Mac that's online with the
ChatGPT app open.
