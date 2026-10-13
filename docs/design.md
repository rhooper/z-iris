# Custom notification sounds: design

Date: 2026-10-13
Status: Draft 2, awaiting review

## Goal

Let the user override notification sounds with their own, chosen per channel,
topic, mention, keyword match, DM and group DM. Clicking a notification opens
the right chat in Zulip Desktop.

## Decision: standalone notifier, not an in-app hook

Zulip web builds the notification and plays the ding inside the webview.
Desktop only receives a muted `Notification` through `electron_bridge`, with a
title string and a message-id tag. Rule matching on that would mean parsing
display text. A separate API consumer sees structured messages and flags
instead.

The work is two independent pieces:

1. A `zulip://` URL handler in this repo.
2. The notifier, z-iris, a new Python repo for macOS at `~/Devel/z-iris`,
   specified here and moved there
   when the repo is created.

Out of scope for now: per-sender rules. The notifier owns all banners and
sounds, and the user turns Zulip's own off in Zulip settings.

## Piece 1: `zulip://` handler (this repo)

### Behaviour

- URL form: `zulip://<host>/#narrow/<operators>`.
- The app registers the `zulip` scheme with the OS.
- On receipt, the main process finds the configured server whose origin host
  matches `<host>`, switches to its tab, and sets only that webview's hash to
  the `#narrow/...` fragment. The page does not reload.
- If the app is not running, it starts and handles the URL once the window and
  server tabs are ready.

### Delivery paths

- macOS: the `open-url` app event.
- Windows and Linux: the URL arrives in `argv` of a second launch
  (`second-instance`) or of a cold start.
- URLs arriving before `whenReady` and window creation are queued, then
  drained in order.
- The existing `second-instance` handler keeps its current show and restore
  behaviour.

### Validation

- Reject any URL whose scheme is not `zulip`.
- Reject hosts that match no configured server. Show a short error dialog.
- Accept only a fragment starting with `#narrow/`. Everything else is
  rejected, so a link can never navigate a tab to a different page.
- The path and query must be empty.

### Files

- `app/main/index.ts`: register the scheme, handle `open-url` and `argv`,
  queue until ready.
- New `app/main/protocol-url.ts`: pure parse and validate function.
- `app/common/typed-ipc.ts`: a new renderer message that carries the target
  server and fragment.
- `app/renderer/js/main.ts`: switch the tab and set the hash.
- `package.json` build config: register the scheme for each platform. macOS
  gets `protocols` in the bundle metadata. Linux gets a `MimeType` handler in
  the desktop entry. Windows gets the installer registration.
- `docs/` and `changelog.md`: document the URL form.

### Testing

- The parse and validate function is pure and gets unit tests: accepted forms,
  wrong scheme, unknown host, bad fragment, extra path or query.
- Manual check on macOS: `open "zulip://<host>/#narrow/channel/…"` with the
  app closed, and again with it running.

## Piece 2: z-iris, the notifier (new repo, Python, macOS only)

A menubar app. It has no Dock icon or main window. It owns all desktop
notification output (banners and sounds) for the user's Zulip servers. Zulip's
own notifications are turned off in Zulip settings, so nothing is doubled.

### Phasing

The user will tune the rules engine and the settings UI after the tool is
streaming real messages. So the first phase proves the pipeline, and the later
phases are built against live traffic.

1. **Streaming and menubar presence.** Connect to the servers, receive
   messages, show a banner, play one default sound, and open the right chat on
   click. The menubar menu shows connection state per server, pause and resume,
   and quit. Settings come from a config file.
2. **Sounds and rules.** Custom sounds with per-rule volume, and the rule kinds
   below. Settings window for sounds, volume and rules.
3. **High-volume handling.** Repetition, intervals, intensity, and batching
   below. Tuned from what phase 1 and 2 show about real traffic.

Phase 1 is the first implementation plan. Phases 2 and 3 get their own plans.

### Connection

- The official Zulip Python client, one event queue per server.
- Credentials from a zuliprc per server, or the macOS Keychain.
- Re-register when the queue expires, and back off on network errors.
- Connection state is visible in the menubar icon and menu.

### Filtering

- Skip the user's own messages.
- Skip muted topics and channels. This uses the user-topic and subscription
  state fetched at registration and kept current by events.
- Use Zulip's own message flags for mentions, wildcard mentions and alert
  words, so the notifier agrees with the server.

### Rules (phase 2)

Each rule has a match and an action. Match kinds: `channel`, `topic`,
`mention`, `keyword`, `dm`, `group_dm`. Keywords are regular expressions,
case-insensitive by default. An optional `server` field limits a rule to one
server.

The action sets:

- `sound`: a file path, `none`, or the default.
- `volume`: 0 to 100 percent of the system output level, per rule and per
  server, with a global master level above both.
- `banner`: whether to show a banner, and how much message text it carries.

Precedence: the most specific matching rule wins. The fixed order is topic,
keyword, mention, channel, group DM, DM, then defaults. Ties go to file order.
An optional integer `priority` on a rule overrides the fixed order. The
settings window edits the same rules the config file holds, and both stay in
sync.

### High-volume handling (phase 3)

Aim: a busy chat stays usable, and the important message still gets through.
The mechanisms below are the starting set. Each is configurable per rule, and
we expect to adjust them after seeing live traffic.

- **Repetition:** repeat a sound N times at an interval until the message is
  read, or until a limit. Typically used for mentions and keywords.
- **Intervals:** a minimum gap between sounds, globally and per channel or
  topic. Messages inside the gap still show or batch, but stay silent.
- **Intensity:** volume that follows urgency. A rule sets a base volume, and
  escalation raises it for repeats, unread mentions, or a burst on a thread.
  Ordinary traffic can also step down, for example a quiet tick after a burst.
- **Batching:** bursts collapse into one banner such as "12 new in #ops", with
  one sound, instead of twelve.
- **Pause and focus modes:** pause from the menubar, optional quiet hours, and
  a mode where only mentions and DMs sound.
- **Read awareness:** a message read in any Zulip client cancels its pending
  repeats and clears its banner.

### Output

- Sound plays through sox, with volume passed per play. The player command is
  configurable, and the default is never `afplay`.
- Banners carry a click action that opens
  `zulip://<host>/#narrow/...` for that message, built from the message's
  channel, topic or DM recipients. The delivery mechanism, a bundled
  terminal-notifier or the native notification framework, is chosen in the
  phase 1 plan after checking which supports a click URL reliably from a
  menubar app.
- Message content is truncated in the banner body.

### Menubar and settings

- Built with a menubar framework such as rumps. The framework is confirmed in
  the phase 1 plan.
- Menu: connection state, pause and resume, mute for a set time, open settings,
  open the config file, quit.
- Settings window arrives in phase 2: servers, sounds, volume, rules.
  Phase 3 adds repetition, intervals, intensity and batching.
- A start-at-login option.

### Testing

- The matcher and the throttling logic are pure functions, tested against
  sample event payloads for every kind, for precedence, and for each
  high-volume mechanism using a fake clock.
- A dry-run mode prints which rule, sound and volume each incoming message
  would use, without playing or posting anything.

## Risks and open items

- Muted-topic and notification-setting details depend on Zulip server version.
  Verify against the server API docs while writing the plan.
- Registering a URL scheme on Linux AppImage and snap builds needs a
  per-format check. macOS is the first target.
- Click-through from a menubar app depends on the banner mechanism. Phase 1
  must prove it end to end before building more on it.
- "Take over desktop notifications" is read here as the notifier owning banners
  and sounds, with Zulip's own turned off in Zulip settings. If it should also
  suppress the desktop app's notifications automatically, that adds a setting
  in this repo, and the spec changes.
- The notifier repo is named z-iris, after the Greek messenger of the gods, and
  lives at `~/Devel/z-iris`.
