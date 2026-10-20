# Brick phone companion

Nidus can invite you to choose a Mac session after an iPhone focus request. A manual shortcut reports your intention to focus. The optional automatic shortcut queries Brick’s own **Is Brick mode enabled?** action after you leave Brick, then relays changes through the same iCloud file. Nidus itself does not connect to Brick or run a network service; the phone performs the state check.

## What happens

When enabled, Nidus watches one JSON file that you choose in iCloud Drive or another location visible in Files. File-change notifications trigger local checks; a recovery check about every 30 seconds covers providers that do not deliver notifications. A fresh, valid request is offered only while Nidus is idle. **Choose session** dismisses the offer and opens the normal session editor. Choose your goal, a saved setup if you want one, and your duration, then explicitly start. **Not now** dismisses the offer. No setup is selected or started by the Brick action. An existing session or break is left alone, and a pending offer expires rather than starting later.

The receiver accepts this small event:

```json
{"version":1,"id":"20261019T143000Z-482731","timestamp":"2026-10-19T14:30:00Z","event":"phone_focus_requested"}
```

`id` is a new unique string of 8–80 ASCII letters, digits, hyphens or underscores for every request; combining the formatted date with a random number works in a native shortcut. `timestamp` is an ISO 8601 date and time. Nidus accepts an event only when it is no more than two minutes old and its clock is no more than 15 seconds ahead. It rejects an already-seen ID, malformed or oversized input, and unknown event types. `phone_focus_cleared` is also accepted, but only to dismiss a pending offer and suppress older delayed requests; it never ends a running session. Enabling the feature, choosing a file, or relaunching Nidus establishes the file's current contents as a baseline; old contents are not offered again. The companion and file permission are opt-in and can be removed in Nidus settings. No saved setup or setup mapping is required.

## Prepared shortcut and minimal iCloud use

For this Mac, a signed shortcut is already imported as **Request Mac Focus**. Its Mac runs have created and overwritten the 101-byte request at `~/Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/nidus-brick.json` (iCloud Drive → Shortcuts). The only cloud file this setup writes is that request. Desktop & Documents synchronization is not required and was not changed by this setup. The user confirmed the same Apple Account on both devices; a fresh iPhone run has now delivered a distinct request recorded by Nidus, with the user confirming the Mac offer and no session starting automatically.

The signed package and reproducible source are in `/Users/posamuel/Downloads/nidus-brick-shortcut-2026-10-19`. The original imported workflow emits a valid `B-<six-digit-random>` ID because its custom date field was empty at runtime. An optional v2 signed package uses two random numbers for greater uniqueness; it is not imported or runtime-tested. Do not ask the user to rebuild the actions manually.

For agent-assisted setup, quit Nidus first and launch the installed executable with `--connect-brick-file <absolute-path>`. This explicit local option requires a readable, structurally valid request no larger than 4 KB; no saved setup is required. Nidus creates and verifies its own bookmark before replacing the selected file and enabling the companion. It accepts an expired initial request as a baseline, and does not start a session. A helper-created app-scoped bookmark is not a reliable substitute. If Nidus is already running, the normal single-instance handoff happens before this option can run. An invalid file reports an error without changing the connection preferences.

## Automatic check when leaving Brick

The prepared **Sync Brick with Nidus** shortcut uses the actual state action from Brick’s [official shared shortcut](https://support.getbrick.com/en/articles/11247233). It is signed and tested. Native off-state execution and the saved app-close automation have been verified on the user’s iPhone, including automatic delivery to Nidus. Physical bricking followed by leaving Brick and automatic on-state delivery to the installed Mac app are also verified.

Import `/Users/posamuel/Downloads/nidus-brick-auto-2026-10-19/Sync Brick with Nidus.shortcut`, let it sync to iPhone, and run it once there to grant access. Then create the iPhone personal automation **App → Brick → Is Closed → Run Immediately → Sync Brick with Nidus**. The shortcut’s actions are already built. On the user’s current phone UI, the equivalent saved configuration is **When Brick is closed → Run Sync Brick with Nidus**, with Automation enabled and Notify off, under Library → Automation. This setup is already complete. Personal automations are device-specific; [Apple’s documentation](https://support.apple.com/en-gb/guide/shortcuts/apd690170742/9.0/ios/26) explains that they do not sync to another device.

Each invocation compares Brick’s current state with `brickState` in the existing request file. Repeated `on` or repeated `off` writes nothing. A new `on` writes a focus request; a new `off` writes a clear event. Missing previous state creates an initial observation. Only that same small JSON file is stored in iCloud. Scheduled background changes without leaving Brick are not covered by this trigger. A clear wins equal-timestamp ties conservatively; a running Mac session remains user-controlled.

## Manual construction reference

Create a shortcut named **Request Mac focus**. Run it manually after you have bricked the phone. Make sure your Brick mode still lets you run Shortcuts; if it blocks Shortcuts, this manual path cannot write the request while that mode is active. Test the exact Brick mode and launch path you plan to use.

1. Add **Current Date**, then **Format Date** in ISO 8601 format. Keep that formatted value for `timestamp`.
2. Format the same Current Date again using the custom pattern `yyyyMMddHHmmss`. This second value is the ID prefix.
3. Add **Random Number** from 100000 to 999999.
4. Add a **Text** action containing the JSON above. Build `id` from the ID prefix, a hyphen, and the random number. Insert the ISO 8601 date variable as `timestamp`. Keep `version` as `1` and `event` as `phone_focus_requested`.
5. Add **Set Name** to name that text `nidus-brick.json`, then **Save File**. Disable **Ask Where to Save**, select a fixed iCloud Drive folder available on both devices, and enable **Overwrite If File Exists**. Action labels may vary with iOS version; confirm the output is one file named `nidus-brick.json`, rather than a new file on every run.
6. Run it once to create the file and let it sync. In Nidus General settings, enable **Brick companion** and select that file. This first request becomes the ignored baseline. Run the shortcut again to send the first request you expect Nidus to offer.

Apple documents Shortcuts' **Save File** action and date formatting; the action editor can show each action's input and output details. This phone-to-Mac path depends on iCloud Drive or the chosen file provider syncing the saved file. It is not instant or guaranteed offline. [Apple's Shortcuts file actions](https://support.apple.com/en-ae/guide/shortcuts/apdaf74d75a5/ios) · [Apple's Shortcuts date formatting](https://support.apple.com/en-jo/guide/shortcuts/apd71b0ac246/ios)

Brick's documented **Brick Block** shortcut can be attached to an iPhone **App Is Opened** automation for enforcement. That is separate from this request signal: the companion shortcut is run after you brick the phone, and its event records your request, not verified Brick state. An NFC-triggered shortcut can also be used as a deliberate request if you choose, but tapping NFC is not evidence that the phone is blocked. [Brick's setup guide](https://support.getbrick.com/en/articles/11247233)

## Limits

This is a one-way relay with no confirmation sent back to the phone and no automatic unbrick action. The automatic wrapper checks Brick’s reported state only when invoked; it does not continuously monitor the phone or prove that an NFC tap succeeded. iCloud Drive delivery can be delayed. Requests already present when Nidus launches are ignored; a running Mac waking from sleep can accept a changed file only while its request is still fresh. The JSON contains a version, event ID, timestamp, event name, and an optional `brickState` deduplication marker. Mac shortcut saving and overwriting in the iCloud Shortcuts folder have been tested. Cross-device delivery from an iPhone run and the visible Mac offer are now verified after a normal Nidus relaunch. The actual Brick off-state query and automatic app-close delivery are verified. Running while physically bricked and automatic on-state receipt were verified on October 19 at 14:34:55 EDT. Repeated-on deduplication and actual on-to-off clearing still need live phone checks.

## Local Mac link

An automation running on the Mac can send the same request using `nidus://brick?id=<unique-id>&timestamp=<percent-encoded-ISO8601>`. The companion must be enabled. This opens an offer to choose a session; it does not start one. Opening this URL on an iPhone does not relay it to the Mac. The file bridge is the cross-device transport described above.
