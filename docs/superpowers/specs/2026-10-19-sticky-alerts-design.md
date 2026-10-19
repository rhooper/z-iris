# Sticky alerts: z-iris-priority.app

2026-10-19. Status: design, awaiting approval (builder check done).

## Why

A DM banner faded while the user was in a meeting, and they missed it. Messages
that match a rule the user marks as important should still be on screen when
they come back, and stay until they deal with them. Everything else stays an
ordinary banner that fades.

macOS sets banner versus alert (an alert stays until dismissed) once per app,
in System Settings, Notifications. There is no supported per-notification
switch. So persistent notifications come from a second app,
**z-iris-priority.app**, whose style is Alerts, while z-iris keeps its
banners.

## Goals

- A per-rule switch, `sticky = true`, makes matching messages appear as
  persistent alerts from z-iris-priority instead of z-iris banners.
- Clicking a sticky alert opens the conversation in Zulip, like a banner click
  (the same `zulip://` URL, opened with `open` and argv only).
- A sticky alert disappears by itself when its message is marked read
  anywhere (phone, web, Zulip Desktop), or is deleted. The user asked for this
  explicitly.
- Nothing is silently lost: if z-iris-priority is missing, not running, or not
  allowed to notify, z-iris shows its ordinary banner instead and logs why
  (`log_problem`, the existing transition-style warnings, once per change).
- Where macOS allows it, sticky alerts are also time-sensitive, so they pass
  Focus and notification summaries. See the entitlement spike below.

## Non-goals

- Changing ordinary banners. They keep fading, and they are not cleared on
  read (that could come later; not part of this work).
- Sounds, flashes, repeats, min_gap and batching stay in z-iris exactly as
  today. z-iris-priority only shows and clears notifications.
- No settings window, no new menubar UI beyond what is listed here.

## Anti-goals

- A sticky alert that stays after the message was read elsewhere. That is
  the one way this feature becomes worse than no feature.
- A message that matched a sticky rule and produced no notification at all.
- Any shell anywhere in the handoff. Message text is data, never a command.

## Constraints (from the project)

- macOS only, Homebrew Python 3.13, the existing `.venv`. Sound only through
  sox. Never read, log or print zuliprc contents.
- A bundle's running process must be the bundle's own `CFBundleExecutable`
  and signed with the bundle id (`-i`), never `--deep`. Otherwise macOS
  refuses notifications without prompting and lists the app under its
  launcher. This was learned today; see CLAUDE.md, Gotchas.
- Tests: `uv run pytest -q`, all passing, new behaviour test-first.
- Scripts live in `scripts/claude/`.

## The design

### The rule switch

- `sticky` joins `config.BEHAVIOUR` as a boolean, default `false`, so a rule
  can set it and `[defaults]` can set it for everything. It reaches
  `Action.sticky`. (`priority` is taken: it already orders rules.)
- `sticky` with `banner = "off"` shows nothing, the same as today: `off` wins.
  `banner = "title"` gives a sticky alert with "New message" as its body.
- The web editor gets a checkbox for it (`editing.RULE_FIELDS`,
  `DEFAULT_FIELDS`, `editor.html` `BUILTIN` and the rule form), and
  `config.example.toml` documents it next to `banner`.
- A batch summary from a sticky rule is a sticky alert.
- Focus decides when sticky rules notify, exactly as for every other rule:
  z-iris's `[focus]` settings (mode, quiet hours) and Pause apply unchanged,
  and macOS Focus applies to the alerts themselves. A sticky message that
  focus drops produces no alert; that is the user's choice, not a lost
  message. (User's answer: "use focus settings to control when notifications
  should message".)

### z-iris-priority.app

- Built by `scripts/claude/build_app.sh` next to z-iris.app (default
  `~/Applications/z-iris-priority.app`), with the same native launcher
  (`launcher.c`), compiled with the module as a build-time define so it runs
  `-m z_iris.priority`.
- Bundle id `ca.toybox.z-iris.priority`, name "z-iris priority",
  `LSUIElement` true, `NSUserNotificationAlertStyle` = `alert` so macOS offers
  Alerts as its starting style, and the z-iris icon. Signed `-i` with its id.
- Module `z_iris.priority`: runs an AppKit run loop (needed for click
  callbacks) and a desktop-notifier `DesktopNotifier`, reusing
  `notify.DesktopNotifierBackend`'s authorisation and refusal handling where
  it fits.
- It accepts two requests: show (title, body, url, optional image path,
  group id) and clear (group id). Clicking opens the url with `notify.open_url`.

### The handoff (builder's choice, with this as the starting point)

- Starting point: z-iris starts z-iris-priority's executable as a child
  process when the first sticky alert is needed, and writes one JSON object
  per line to its stdin; z-iris-priority answers each with one JSON line
  (`ok`, or the reason it fell back). Restart it if it has died; fall back to
  a banner if it cannot start. No shell, argv only, text only as JSON data.
- The spike below must confirm that a child started this way is treated by
  macOS as z-iris-priority (its own notification permission and alert style),
  not as z-iris. If not, launch it through LaunchServices (`open -a ... -g`)
  and talk over a Unix socket in `~/Library/Application Support/z-iris/`
  instead. Either way the Python side is a `Notifier`-shaped object with
  `show` and `clear`.
- A click on an alert that is still on screen after z-iris quit or restarted
  should still open Zulip: macOS relaunches z-iris-priority to deliver the
  click, and it must handle that click when launched without z-iris, then
  exit when idle.

### Clearing on read

- The engine already sees `update_message_flags` read events and deletions
  (`Engine.handle_event`, `_forget`). It also asks the output to clear the
  sticky alerts for those message ids on that server, and for the whole
  server when the event says `all`.
- The output remembers which (server, message id) it showed as sticky, and
  their group ids (`banner_group`), so clearing only touches alerts that
  exist. A batch summary's alert is cleared when the message it points at
  (the latest one) is read.
- After a Zulip event queue is re-registered inside a running z-iris (a Mac
  that slept through a meeting loses its queue), z-iris checks its remembered
  sticky (server, id) pairs against the server's current unread messages and
  clears any that are no longer unread. Read events in the gap are otherwise
  lost. (Design author's call: the user asked that read messages disappear.)
- Clearing must work after a z-iris restart for alerts still on screen:
  z-iris-priority can list its delivered notifications, so a clear by group
  id still works even if z-iris forgot it. Which ids to clear after a restart
  (for messages read while z-iris was down) is not required.

### Routing in z-iris

- `RealOutput._show_banner` sends the notification to the priority notifier
  when `action.sticky` is set, otherwise to the existing notifier. If the
  priority notifier says it fell back, z-iris shows the banner itself.
- If z-iris-priority is allowed to notify but its style is Banners or None
  (`UNNotificationSettings.alertStyle`), z-iris logs one warning saying to set
  Alerts, and still sends to it. (Design author's call.)
- `--dry-run` prints `sticky` in its description line. `make_notifier`'s
  fallback (terminal-notifier outside the bundle) stays as is: outside the
  bundle, sticky messages are ordinary banners.

## First task: the spikes (throwaway, before building)

1. **Time-sensitive without a paid account.** Build a test z-iris-priority
   with the entitlement `com.apple.developer.usernotifications.time-sensitive`,
   ad-hoc signed. Does macOS launch it? Does System Settings show a Time
   Sensitive switch for it? Does a time-sensitive notification (desktop-notifier
   `Urgency.Critical`) arrive as time-sensitive? If launching fails, use the
   free Personal Team: the user has enabled it, and the identity
   "Apple Development: Rose Hooper (W2W8Y49E9J)" is valid on rubik. A
   development profile for `ca.toybox.z-iris.priority` with the Time Sensitive
   capability has to be created (Xcode makes it for a project with that bundle
   id). The user accepts re-signing when a free profile expires; if it is
   used, `build_app.sh` takes the identity and profile (embedded as
   `Contents/embedded.provisionprofile`), and z-iris logs a warning when the
   profile is within 2 days of expiry. If neither works, ship without
   time-sensitive and tell the user.
2. **Child process identity.** Started as a child of z-iris, does
   z-iris-priority get its own permission prompt and its own entry in System
   Settings, Notifications, with the Alerts style honoured?

Report both results to the user before the main build.

## What the user does once

- Allow notifications for z-iris priority when macOS asks, and check its
  style is Alerts in System Settings, Notifications.
- Set `sticky = true` on the rules that matter (the DM rule).

## Left to the builder

- Module layout inside `z_iris.priority`, the JSON field names, restart and
  idle-exit timings, how the image path is passed, and how tests fake the
  child process. Keep the existing style: small pure functions, injected
  clocks and spawners, no real notifications in tests.
