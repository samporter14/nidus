# Automation

Nidus can be driven from Shortcuts, `nidus://` links, launchers (Raycast,
Alfred, BetterTouchTool) and assistants. This page is for Nidus 0.3.0 or
later. Everything goes through the same rules as the popover:

- A strict session can't be ended from outside. It ends from the menu bar,
  behind its phrase.
- A start never replaces a session or break that's already on.
- Status never changes anything.

Nothing here needs the internet. Nidus never connects to it.

## Shortcuts actions

Nidus adds six actions to the Shortcuts app. Search for "Nidus" or "Focus" in
a shortcut's action list.

| Action | Fields | What it does |
| --- | --- | --- |
| Start Focus | Setup, Goal, Minutes (0 to 1440), Categories | Starts a session, and answers with a sentence like "Started Writing for 45 minutes." |
| Add Focus Time | Minutes (1 to 1440, 5 to begin with) | Adds time to the session that's on, and returns its status. |
| Get Focus Status | None | Says where things stand, and returns the fields below. Changes nothing. |
| End Focus | None | Ends the session, or the break after it. A strict session can't be ended. |
| Toggle Focus | None | Ends a session that's on. Otherwise starts the last one again. |
| Run Nidus Command | Request (JSON text) | For scripts and assistants. See [The JSON command](#the-json-command). |

**Start Focus.** Every field is optional. What you leave out comes from the
popover's choices (its length and categories), so a plain Start Focus starts
what the popover's Start button would, with no goal. A goal half-typed in the
popover is never used.

- **Setup** is one of your saved setups. Nidus keeps it by id, so renaming it
  doesn't break a shortcut.
- **Goal** is one line of text: what you're working on. A blank goal counts as
  left out, so it doesn't wipe a setup's goal.
- **Minutes** is the length. 0 is open-ended. Leave it out for your usual
  length.
- **Categories** is what to block (or allow, in allow mode). Leave it out for
  your picks in Nidus.
- Choose a setup and the other fields change it for this session only. The
  saved setup stays as it was.
- Start Focus has no strict field. A strict setup starts strict, and nothing
  you fill in switches that off. Strict only ever turns on.
- A setup you've deleted since is an error, not a fallback to the popover's
  choices. The same goes for categories that are gone.

**Toggle Focus.** With nothing on, it starts the last session again, or the
popover's choices if there is no last one. On a break, it skips the break and
starts the next session. During a strict session, it refuses.

**End Focus.** During a strict session it refuses, and Nidus puts up its
strict card on screen. With nothing on, it says "Focus isn't on." and doesn't
fail.

### What Get Focus Status returns

| Field | Means |
| --- | --- |
| Session on | Yes while a session is running or paused. No when idle or on a break. |
| State | `idle`, `running`, `paused` or `break`. |
| Blocking | Yes when apps and websites are being blocked right now. |
| Open-ended | Yes for a session with no end time. |
| Strict | Yes for a strict session. |
| Minutes left | Whole minutes, rounded up, of the session. Empty when idle, open-ended or on a break. |
| Break minutes left | Whole minutes, rounded up, of the break. Empty when you're not on one. |
| Ends at | When the session or break ends. Empty when idle, open-ended or paused. |
| Checked at | When Nidus read all this. |
| Summary | The sentence below, as text you can hand to the next action. |

It also answers with a sentence, kept in Summary: "Focus is off.", "Focus is on, 33 minutes left.",
"Focus is on, open-ended.", "Focus is paused, 12 minutes left." or "On a
break, 4 minutes left."

Minutes left is the session's only, and stays empty on a break, as it did in
0.2.0. A shortcut that tests it doesn't mistake a break for focus. Use Break
minutes left for the break.

A paused session isn't focusing. Session on stays yes, because the session
is still there, so use Blocking to ask whether anything is being blocked. A
pause you chose blocks nothing.

While the Mac is locked or asleep, the session's clock pauses but blocking
stays on, so a blocked tab doesn't reappear behind the lock screen. Status
says so: State is `paused`, Blocking is yes, and it reads "Focus is paused
while your Mac is locked, 12 minutes left. Blocking stays on."

### When an action says no

Shortcuts shows these messages.

| Message | When |
| --- | --- |
| Nidus is still starting. Try again in a moment. | Nidus wasn't ready within 5 seconds. |
| A focus session or a break is already on. | Start Focus, with something already on. |
| This is a strict session. End it from the menu bar. | End Focus or Toggle Focus, during a strict session. |
| There is nothing to block. Add apps or websites to a category in Nidus. | Start Focus or Toggle Focus, when every chosen category is empty. |
| Minutes must be from 0 to 1440. | Start Focus. |
| That setup isn't in Nidus anymore. Choose another. | Start Focus, with a deleted setup. |
| Those categories aren't in Nidus anymore. Choose others. | Start Focus, when none of the categories exist now. |
| Minutes must be from 1 to 1440. | Add Focus Time. |
| Focus isn't on, so there's nothing to add to. | Add Focus Time, with nothing on. |
| This session is open-ended, so there's no end to move. | Add Focus Time. |
| You're on a break, so there's no session to add to. | Add Focus Time. |
| Nothing added: a session can't run more than 24 hours. | Add Focus Time, with less than a minute of room under the limit. When more than a minute fits but not all you asked for, Nidus adds the whole minutes that fit and says how much. |

### Siri, Spotlight and keys

On macOS the actions live in the Shortcuts app. Apple's Human Interface
Guidelines say App Shortcuts, the Siri and Spotlight phrases, aren't
supported in macOS. Don't count on "Hey Siri" phrases on a Mac. Nidus declares
phrases anyway, so its metadata is complete. Spotlight on recent macOS can
list app actions, but that's untested here.

For a keyboard shortcut, make a shortcut that runs Start Focus (or Toggle
Focus). Then open the shortcut's details and give it a key.

## Links

| Link | Does |
| --- | --- |
| `nidus://start` | Starts a session with the popover's choices. |
| `nidus://start?goal=Write&minutes=45&categories=social,video` | Starts one with these. See the table below. |
| `nidus://end` | Ends a session, or a break. Refused during a strict one. |
| `nidus://toggle` | Ends a session, or starts the last one again. Refused during a strict one. |
| `nidus://popover` | Opens the popover. |
| `nidus://snooze?site=youtube.com` | Snoozes one site. The block page uses it. |

What `nidus://start` takes:

| Parameter | Means |
| --- | --- |
| `goal` | One line of text, up to 200 characters. A blank goal counts as left out: it doesn't wipe a setup's goal. |
| `minutes` | 0 to 1440, in digits. 0 is open-ended. Leave it out for your usual length. |
| `categories` | Category ids or names, with commas between. Any case. A name that matches nothing is dropped. If none match, nothing starts. |
| `mode` | `block` or `allow`. |
| `strict` | `1`, `true` or `yes` turns strict on. `0`, `false` or `no` leaves it to the setup, or to Settings. Strict only turns on. |
| `preset` | A setup's id or exact name. Its choices come first, and the link's own parameters win over them. |

An empty value counts as left out. A value that isn't usable (say,
`minutes=2.5`) makes Nidus ignore the whole link.

Encode spaces as `%20`: `nidus://start?goal=Write%20the%20paper&minutes=45`.
A `+` also reads as a space, so write a real plus as `%2B`.

A link only asks. It gets no answer back, so a launcher can't tell you
whether a session started. Nidus ignores a link that can't start (a session
is already on, nothing to block, no such setup) and logs the reason, never
the goal. Use Shortcuts or the JSON command when you need the answer.

Any web page can open a `nidus://` link too, and the browser asks first. A
link can start a session, but it can't get around strict mode: strict
sessions can't be ended by a link, and `snooze` does nothing in one.
`snooze` also does nothing when no session is on.

**Copy Launch Link.** Right-click a setup in the popover and choose Copy
Launch Link. Or open Settings → Setups, choose the setup, and press Copy
beside Launch link. Either puts `nidus://start?preset=<id>` on the clipboard.
The id belongs to that setup on that Mac, and renaming the setup doesn't
break the link. The goal isn't in it.

## Raycast

The file `integrations/raycast/nidus-quicklinks.json` holds four Quicklinks:

| Quicklink | Link |
| --- | --- |
| Nidus: Start Focus | `nidus://start` |
| Nidus: Focus for 45 Minutes | `nidus://start?minutes=45` |
| Nidus: Open Controls | `nidus://popover` |
| Nidus: End Focus | `nidus://end` |

Import it with Raycast's Import Quicklinks command. Nidus never imports it
for you. Then give each Quicklink an alias or hotkey in Raycast Settings →
Quicklinks. A Quicklink for one setup is the same thing: paste that setup's
launch link into a new one.

**Untested.** Raycast's manual says deeplinks with no "Open With" are routed
by the browser. If a browser asks "Open Nidus?", allow it, or set the
Quicklink's Open With to Nidus.

**Follow-up, not built.** Script Commands for status and Add Time that use the
`nidus-focus` helper, and a full extension with a setup list, a start form
and Add 5 and Add 15 buttons. Links can't answer and can't add time, so these
would need the native actions. They must not read Nidus's private files to
get around that.

## Alfred

Alfred's workflows need the Powerpack. A workflow that starts a session:

1. Add a Keyword input, such as `focus`, with an argument.
2. Connect a Run Script action: language `/bin/zsh`, "with input as argv".
3. Connect a Post Notification action to show the answer.

For typed input like `focus 45 Write the paper`, run the helper with
structured arguments. Don't paste `{query}` into a URL or into shell text. A
goal with a quote or a `$` in it would break the script, or worse. With
"with input as argv" the query arrives as `$1`, and the helper takes it as
data:

```zsh
# "45 Write the paper": minutes, then the goal. No number: it's all goal.
read -r first rest <<< "$1"
args=(start --no-default --id "$(uuidgen)")
if [[ "$first" == <-> ]]; then
    args+=(--minutes "$first")
    goal="$rest"
else
    goal="$1"
fi
[[ -n "$goal" ]] && args+=(--goal "$goal")
"$HOME/.agents/skills/nidus-focus/scripts/nidus-focus" "${args[@]}" \
    | plutil -extract message raw -o - -
```

The helper path is where [the assistant skill](#assistant-skill) installs it.
Point it at any copy you keep. `--no-default` stops a `default-setup` file, if
you made one for an assistant, from changing what this keyword starts. The
helper needs the "Nidus Command" shortcut from
[Making the wrapper](#making-the-wrapper-once).

For a fixed length with no typing, a Run Script of
`open "nidus://start?minutes=45"` works too, but it gets no answer back.

Alfred's Open URL action is documented as opening in your browser. Its
handling of a custom scheme is untested, so prefer Run Script. No workflow is
shipped.

## BetterTouchTool

BetterTouchTool's "Run Apple Shortcut" action (the in-app name may be "Run
Shortcut from Shortcuts App") runs a shortcut you made. Make one from Start
Focus or Toggle Focus, then give it any trigger BetterTouchTool offers: a
key, a mouse button, a trackpad gesture.

## The JSON command

For scripts and assistants. One request in, one answer out, through the Run
Nidus Command action. It is version 1. The answer is always JSON, even for a
request Nidus can't read, and even when Nidus isn't running.

### The request

| Field | Type | For | Means |
| --- | --- | --- | --- |
| `version` | number | all | `1`. Leave it out for 1. Anything else is refused. |
| `action` | string | all | Required. `status`, `setups`, `start`, `addTime` or `end`. Case matters. |
| `id` | string | `start`, `addTime`, `end` | Any string you make up, once per request. A blank one counts as none. See [Request ids](#request-ids). |
| `goal` | string | `start` | One line, trimmed, up to 200 characters. Leave it out for the setup's goal, if it has one, or none. A blank goal counts as left out, so it doesn't wipe the setup's. |
| `minutes` | number | `start`, `addTime` | For `start`, 0 to 1440, and 0 is open-ended. Leave it out for the setup's length, then your usual one. For `addTime`, 1 to 1440, and required. |
| `setup` | string | `start` | A setup's id or exact name, in any case. Its choices come first, and the fields here win over them. A blank one is no setup. |
| `categories` | array of strings | `start` | Category ids or names, in any case. Names that match nothing are dropped. If none match, nothing starts. An empty list means the same as leaving it out. |
| `mode` | string | `start` | `block` or `allow`. |
| `strict` | boolean | `start` | `true` turns strict on. `false` does nothing: strict only turns on. |

Fields Nidus doesn't know are ignored. A field of the wrong type (`"minutes":
"45"`) makes the request unreadable.

### The answer

| Field | Means |
| --- | --- |
| `version` | `1`. |
| `ok` | `true` when it did what was asked. |
| `action` | The request's action, echoed back. |
| `outcome` | One word for how it came out. The table below lists them. |
| `message` | A sentence you can say to the user. |
| `status` | Where things stand, after the request. Left out when Nidus isn't running. |
| `addedMinutes` | `addTime` only: the minutes actually added. 0 at the limit. |
| `setups` | `setups` only: a list of your setups. |
| `duplicate` | `true` when this is an earlier answer given again. Left out otherwise. |

Fields with nothing to say are left out, not set to `null`.

`status` has these fields. It's the same picture Get Focus Status gives.

| Field | Means |
| --- | --- |
| `state` | `idle`, `running`, `paused` or `break`. |
| `isOn` | A session is running or paused. |
| `isBlocking` | Apps and websites are being blocked right now. |
| `isOpenEnded` | A session with no end time. |
| `isStrict` | A strict session. |
| `minutesLeft` | Whole minutes of the session, rounded up. Left out when idle, open-ended or on a break, so a break isn't read as focus. |
| `secondsLeft` | The same in seconds. Left out in the same cases. |
| `breakMinutesLeft` | Whole minutes of the break, rounded up. Left out when you're not on a break. |
| `endsAt` | When the session or break ends, as a date with the Mac's time zone (`2026-10-06T15:00:00-04:00`). Left out when idle, open-ended or paused. |
| `observedAt` | When Nidus read this, in the same form. |
| `browsersNeedingAccess` | Names of running browsers Nidus may not control yet. Only filled while a session is on. |
| `sentence` | The sentence Get Focus Status says. |

Each item in `setups` has `id`, `name`, `summary`, `minutes` and `strict`.

### Outcomes

| Action | Outcome | `ok` | Means |
| --- | --- | --- | --- |
| any | `invalidRequest` | no | Not JSON, or no `action`, or a field of the wrong type. `action` comes back empty. |
| any | `unsupportedVersion` | no | `version` isn't 1. |
| any | `notReady` | no | Nidus isn't running, or is still starting. No `status`. |
| any | `unknownAction` | no | The action isn't one of the five. |
| `start`, `addTime`, `end` | `idReused` | no | The `id` was already used, within the last ten minutes, for a different request. Nothing was done. Use a new id. |
| `status` | `ok` | yes | Here's where things stand. |
| `setups` | `ok` | yes | Here are your setups. |
| `start` | `started` | yes | A session started. |
| `start` | `busy` | no | A session or a break is already on. Nothing new started. |
| `start` | `nothingToBlock` | no | Every chosen category is empty. |
| `start` | `invalidMinutes` | no | Minutes outside 0 to 1440. |
| `start` | `invalidMode` | no | Mode isn't `block` or `allow`. |
| `start` | `setupNotFound` | no | No setup has that id or name. |
| `start` | `setupAmbiguous` | no | More than one setup has that name. Use its id. |
| `start` | `noMatchingCategory` | no | None of the categories is one of yours. |
| `addTime` | `added` | yes | Time was added. `addedMinutes` says how much. |
| `addTime` | `atMaximum` | no | A session can't run more than 24 hours, and there's less than a minute of room left. Nothing was added. `addedMinutes` is 0. |
| `addTime` | `openEnded` | no | An open-ended session has no end to move. |
| `addTime` | `onBreak` | no | A break has no session to add to. |
| `addTime` | `nothingRunning` | no | Nothing is on. |
| `addTime` | `invalidMinutes` | no | Minutes missing, or outside 1 to 1440. |
| `end` | `ended` | yes | The session ended. |
| `end` | `endedBreak` | yes | The break ended, with no session after it. |
| `end` | `nothingRunning` | no | Nothing is on. |
| `end` | `refusedStrict` | no | A strict session. Nothing ended. Nidus shows its strict card. |

`addTime` adds whole minutes only, as many as fit under the 24-hour limit.
When fewer fit than you asked for, it adds those and answers `added`, with the
smaller `addedMinutes`. With less than a minute of room it answers
`atMaximum`.

### Examples

Nidus writes each answer on one line with the keys sorted. These are
wrapped. After the first two, `status` is cut to `{ ... }`.

**Status.** Ask:

```json
{"version": 1, "action": "status"}
```

Answer:

```json
{
  "action": "status",
  "message": "Focus is on, 33 minutes left.",
  "ok": true,
  "outcome": "ok",
  "status": {
    "browsersNeedingAccess": [],
    "endsAt": "2026-10-06T15:00:00-04:00",
    "isBlocking": true,
    "isOn": true,
    "isOpenEnded": false,
    "isStrict": false,
    "minutesLeft": 33,
    "observedAt": "2026-10-06T14:27:00-04:00",
    "secondsLeft": 1980,
    "sentence": "Focus is on, 33 minutes left.",
    "state": "running"
  },
  "version": 1
}
```

**Status on a break.** The session's `minutesLeft` and `secondsLeft` are left
out, and `breakMinutesLeft` has the break's minutes. `endsAt` is when the
break ends.

```json
{
  "action": "status",
  "message": "On a break, 4 minutes left.",
  "ok": true,
  "outcome": "ok",
  "status": {
    "breakMinutesLeft": 4,
    "browsersNeedingAccess": [],
    "endsAt": "2026-10-06T14:31:00-04:00",
    "isBlocking": false,
    "isOn": false,
    "isOpenEnded": false,
    "isStrict": false,
    "observedAt": "2026-10-06T14:27:00-04:00",
    "sentence": "On a break, 4 minutes left.",
    "state": "break"
  },
  "version": 1
}
```

**Start with a setup.** Ask:

```json
{"version": 1, "action": "start", "id": "4F0E8A52-6B1C-4C3E-9D0A-2B7F5E1A8C34",
 "setup": "Writing", "minutes": 45}
```

Answer:

```json
{
  "action": "start",
  "message": "Started Writing for 45 minutes.",
  "ok": true,
  "outcome": "started",
  "status": { ... },
  "version": 1
}
```

**Add time, with an id.** Ask:

```json
{"version": 1, "action": "addTime", "id": "9B2C7E40-1D5A-4F68-A3E2-5C8D0F7B1A96",
 "minutes": 15}
```

Answer:

```json
{
  "action": "addTime",
  "addedMinutes": 15,
  "message": "Added 15 minutes. You have 48 minutes left.",
  "ok": true,
  "outcome": "added",
  "status": { ... },
  "version": 1
}
```

Send the same request again, with the same id, and Nidus adds nothing. It
gives the first answer back, marked as a duplicate, with `status` read fresh.
The `message` is still the first one's, so its "48 minutes left" can be a
minute out of date.

```json
{
  "action": "addTime",
  "addedMinutes": 15,
  "duplicate": true,
  "message": "Added 15 minutes. You have 48 minutes left.",
  "ok": true,
  "outcome": "added",
  "status": { ... },
  "version": 1
}
```

**A busy start.** Ask:

```json
{"version": 1, "action": "start", "minutes": 25}
```

Answer, with a session already on:

```json
{
  "action": "start",
  "message": "A session or break is already on, so nothing new started. Focus is on, 18 minutes left.",
  "ok": false,
  "outcome": "busy",
  "status": { ... },
  "version": 1
}
```

**Ending a strict session.** Ask:

```json
{"version": 1, "action": "end"}
```

Answer:

```json
{
  "action": "end",
  "message": "This is a strict session. End it from the menu bar.",
  "ok": false,
  "outcome": "refusedStrict",
  "status": { ... },
  "version": 1
}
```

### Making the wrapper, once

`shortcuts run` runs a shortcut by name, not a single action. So Run Nidus
Command needs a one-step shortcut around it, which you make once.

1. Open Shortcuts and make a new shortcut. Call it exactly **Nidus Command**.
2. Add **Get Text from Input**, with Shortcut Input.
3. Add **Run Nidus Command** (from Nidus), and set its Request to the Text
   from step 2.
4. Add **Stop and Output**, with the Result of step 3.

Check it with `nidus-focus check`, which runs nothing. Then try
`nidus-focus status`, which only reads.

### The helper

`integrations/assistant-skill/nidus-focus/scripts/nidus-focus` builds a
request, runs the wrapper with it and prints Nidus's answer. It puts your
values in the request as data, never as shell text, so a goal can hold any
characters.

| Command | Does |
| --- | --- |
| `nidus-focus status` | Says what's on. Changes nothing. |
| `nidus-focus setups` | Lists your setups, with their ids. |
| `nidus-focus start [--setup NAME_OR_ID] [--goal TEXT \| --goal-file PATH] [--minutes N] [--id ID] [--no-default]` | Starts a session. |
| `nidus-focus add MINUTES [--id ID]` | Adds time. MINUTES can come anywhere among the options, so `add --dry-run 15` works. |
| `nidus-focus end [--id ID]` | Ends the session. Never a strict one. |
| `nidus-focus check` | Says whether Nidus and the wrapper are in place. Runs nothing. |

`--dry-run` prints the request instead of sending it. `--shortcut NAME` (or
the `NIDUS_SHORTCUT` variable) names the wrapper if it isn't "Nidus Command".
The helper has no options for categories, mode or strict. For those, send
your own JSON to the wrapper:
`shortcuts run "Nidus Command" --input-path request.json`.

Exit status: 0 when Nidus answered, so read `ok` and `outcome`. 1 when it
couldn't be reached. 2 for a mistake in how the helper was run.

When the helper has to answer itself, it uses the same shape (`version`,
`ok`, `action`, `outcome`, `message`, and no `status`) with these outcomes:

| Outcome | Means |
| --- | --- |
| `ready` | `check` found Nidus and the wrapper. `ok` is true. |
| `nidusMissing` | `check` didn't find Nidus in Applications. |
| `wrapperMissing` | There's no shortcut with the wrapper's name. |
| `unavailable` | This Mac has no `shortcuts` command. |
| `shortcutFailed` | The wrapper didn't finish. |
| `unexpectedAnswer` | The wrapper answered, but not with Nidus's JSON. Check that it ends with Run Nidus Command's result. |
| `invalidMinutes` | Minutes weren't a whole number. Exit status 2. |
| `internalError` | The helper couldn't write the request. |

`check` exits 0 whether or not things are in place, so read its `ok`. The
one exception is a Mac with no `shortcuts` command, which exits 1.

### Request ids

A start, an add or an end can take an `id`. Make a new one for each request
you mean as new (`uuidgen` will do). If a call times out and you send it
again, send the same id. Nidus then gives the first answer back, with
`"duplicate": true`, instead of starting twice or adding time twice.

- An id counts for one action: `start` and `end` with the same string are two
  different requests.
- Only answers with `"ok": true` are remembered. A refusal such as `busy`
  changed nothing, so it isn't remembered: send it again with the same id and
  it runs again.
- Nidus remembers an answer for ten minutes, and keeps the last 32. They're in
  memory only, so after Nidus relaunches it has forgotten them. Check status
  before you retry anything.
- The same id with a different request (another goal, another number of
  minutes) isn't the same request. It gets the outcome `idReused`, with `ok`
  false, and nothing is done. Use a new id.
- A blank id counts as no id.
- `status` and `setups` don't use ids.

### Starts and browser access

A start from the JSON command doesn't raise macOS's browser permission
prompts, because nobody may be at the screen. The popover, Start Focus and
links do raise them. After a JSON start, read `status.browsersNeedingAccess`.
Those running browsers are ones Nidus may not control yet, so their websites
aren't blocked, however long the clock runs. The user can allow them in
Settings → Blocking → Browsers.

The list fills in once Nidus has checked the browsers, a moment after a
session starts. An empty list in a start's own answer means "not checked
yet", not "all blocked": ask for `status` a few seconds later and trust that.

## Assistant skill

The folder `integrations/assistant-skill/nidus-focus/` (its `SKILL.md` and
`scripts/nidus-focus`) is optional. It lets an assistant on your Mac start a
setup, add time, say how long is left or end a session, through the helper
and the wrapper.

- **What it tells the assistant.** Pass only what you said, so it doesn't
  choose categories, strict mode or a length for you. Say so when a setup
  isn't there, rather than starting another. Never end a session you didn't
  ask to end. After a timeout, run status before retrying anything. Report
  success only when the answer has `"ok": true`.
- **To install:** copy the folder to `~/.agents/skills/` for the ChatGPT
  desktop app, Codex CLI or IDE (per OpenAI's skills docs). Nidus doesn't
  install it.

  ```sh
  mkdir -p ~/.agents/skills
  cp -R integrations/assistant-skill/nidus-focus ~/.agents/skills/
  ```

  Then make the wrapper, as above.
- **Dots:** a ChatGPT dot can use local skills only through a connected Mac
  that's online with the ChatGPT app open (per OpenAI's dots docs). It isn't
  available from the web or phone on its own, and this path hasn't been
  tested end to end.
- **Default setup:** to make one the default for "start my focus session",
  put its name or id on the first line of a file called `default-setup` in
  the skill folder. A start that doesn't name a setup then uses it.
  `--no-default` skips it.

## MCP: a possible follow-up, not built

A thin local stdio MCP server could expose `start_focus`, `get_focus_status`
and `add_focus_time` by calling the same helper and wrapper. It would hold no
blocking rules of its own, and it would never be a way around strict mode.
The desktop app can run local stdio MCP servers (Settings → MCP servers, or
`~/.codex/config.toml`). ChatGPT on the web can't reach a local one.

## Privacy

Nidus sends nothing off the Mac. It has no server to send to. What the helper
prints goes to whichever assistant ran it, and an answer includes your setup
names and summaries (which say what each one blocks) and the status sentence.
An assistant has that, and whatever you said to it, so what it does with it is
between you and the assistant. Links, Shortcuts and launchers keep it all on
the Mac.

`focus.json`, which Bench reads, is unchanged. It still holds only whether a
session is on and until when, never goals or what's blocked. Paused or on a
break doesn't count as focusing.

Goals passed in requests aren't logged. When Nidus ignores a link, it logs
the reason, never the goal. The helper keeps its request, which can hold a goal, in a
temporary folder only until it finishes.

## Checking it on your Mac

None of these live checks had been done when this was written. What was
checked: unit tests with fake sessions, the build, and the Shortcuts metadata
in the built app. Work down the list in order.

1. Open Shortcuts and search for "Nidus". Start Focus, Add Focus Time, Get
   Focus Status, End Focus, Toggle Focus and Run Nidus Command should all be
   there after install.
2. Make the wrapper. Run `nidus-focus check`, which should say ready. Then
   run `nidus-focus status`. It only reads, so it's the first live test.
3. A cold launch: quit Nidus, then run `nidus-focus status`. It should
   launch Nidus and answer.
4. Make a test setup in block mode that blocks only a harmless app, one you
   opened for the test. Don't use allow mode: it quits everything else. Start
   it with `nidus-focus start --setup 'Test'`.
5. Run `nidus-focus add 15 --id test-1` twice, within ten minutes. The second
   answer should say `"duplicate": true`. Check with `nidus-focus status` that
   15 minutes were added once. Then run `nidus-focus add 20 --id test-1`: the
   answer should be `idReused`, and nothing should be added. Then run
   `nidus-focus end` to end the test session.
6. End a strict session from outside. Make the test setup strict, start it,
   and run `nidus-focus end`. The answer should be `refusedStrict`, and the
   session should still be on. End it from the menu bar.
7. A Raycast Quicklink: with nothing on, import the file and run Nidus: Focus
   for 45 Minutes. It starts a real session with the popover's categories, so
   pick a moment when that's fine. Allow the browser's "Open Nidus?" if it asks. Then run
   Nidus: End Focus.
8. The dot workflow: from a dot, ask for the status, then ask it to start the
   test setup, then to end it.
