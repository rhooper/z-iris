# z-iris

A macOS menubar app that streams your Zulip messages and tells you about the
ones that matter, with your own sounds. Named after Iris, the Greek messenger
of the gods.

- **Rules** pick the sound, volume, banner and screen flash per channel (names
  or patterns), topic, keyword, mention, DM or group DM, edited in a native
  editor window that keeps your config file's comments.
- **Notifications show the sender's face**, can stay on screen for a set time or
  until read, and disappear when you read the message elsewhere.
- **Sounds**: built-in tones, Yamaha DX7- and Minimoog-style synth voices, Morse
  SOS, public-domain recordings (see `swift/Resources/sounds/SOURCES.md`), or
  your own.
- **Repeats, batching, focus and quiet hours** keep busy channels in check.
- Clicking a notification opens the conversation in Zulip Desktop.

macOS 26 or later on Apple silicon. Written in Swift. MIT licensed.

## Build and install

Download `z-iris-<version>-macos-arm64.zip` from the
[releases](https://github.com/rhooper/z-iris/releases) and move both apps,
`z-iris.app` and `z-iris-priority.app`, to `~/Applications`. Or build from
source with Xcode 27's toolchain:

```sh
cd swift && swift test && cd ..
scripts/claude/build_app.sh          # z-iris.app and z-iris-priority.app in ~/Applications
```

Keep the two apps side by side; z-iris priority shows the alerts that stay on
screen. Built from source and signed ad hoc, notifications are plain; sender
faces and time-sensitive alerts need development profiles (see Sender faces).
`scripts/claude/build_release.sh` makes the signed, notarized release zip.

1. Create `~/.config/z-iris/config.toml` from
   [`config.example.toml`](config.example.toml), pointing `zuliprc` at a
   zuliprc file for your Zulip account (Zulip: Settings, Account & privacy, API
   key, download zuliprc).
2. Open `~/Applications/z-iris.app`. Allow its notifications when macOS asks,
   and allow z-iris priority's the first time a sticky alert appears. In System
   Settings, Notifications, z-iris priority, choose Persistent.
3. Turn off Zulip's own desktop notifications and sounds so nothing is doubled.

Clicking a notification opens a `zulip://` link, which needs a Zulip Desktop
build with `zulip://` support (not yet in an official release).

## Use

```sh
z-iris                      # menubar app (the bundle's Contents/MacOS/z-iris)
z-iris --dry-run            # print what would notify; play nothing
z-iris --headless           # stream without the menubar
z-iris probe                # check the server connection and response shape
z-iris edit                 # the rules editor alone
z-iris normalize [--dir DIR] [--no-backup]
z-iris flash top '#0066ff' 1
z-iris play FILE [volume] [device]
```

From the checkout, `cd swift && swift run z-iris ...` runs the same commands
with the tones from `swift/Resources`.

## What notifies by default

- Direct messages and group DMs.
- Personal @-mentions, wildcard mentions and your alert words.
- Optionally every unmuted channel message (`notify_channel_messages = true`).
- Never your own messages. Muted channels and topics are respected, except for
  a personal @-mention, which still notifies.

## Rules and volume

Rules live in `~/.config/z-iris/config.toml` as `[[rule]]` tables, and the file
reloads while z-iris runs (menubar: Reload config). `config.example.toml` has
one sample per kind.

- `match`: `channel`, `topic`, `keyword`, `mention`, `wildcard`, `alert_word`,
  `dm` or `group_dm`; `conversation` and `reaction` are described below. `mention` is @you only and `wildcard` is @all, @everyone,
  @channel or @topic; `alert_word` is your own Zulip alert words. Topic and
  keyword values are case-insensitive regular expressions, written as Python's
  `re` reads them (as the first version was in Python).
- `description`: optional text shown in the editor, logs and the dry run;
  without one a rule is shown by what it matches ("Channel #ops, #deploys").
  Older configs' `name` is read as the description.
- `channel`: one channel or a list, `channel = ["ops", "infra-.*"]`. Each entry
  is a case-insensitive regular expression for the whole channel name, so `ops`
  is exactly #ops and `ops-.*` matches #ops-east and #ops-west.
- `sound`: `none`, a bundled tone (chime, ping, bell, blip, knock, double,
  triple, rise, fall, alert, urgent, low, soft, mid-short, mid-long; the DX7-style
  `dx-*` voices; moog-a; sos; eleven public-domain recordings), or a file in
  `~/.config/z-iris/sounds/` (its name without the extension). `volume`: 0 to
  100. `banner`: `full`, `title` (no message text) or `off`. `server`: one server.
- Precedence: higher `priority` first, then topic, keyword, mention, wildcard,
  alert word, channel, group DM, DM, then file order.
- Final volume is rule volume (or `[defaults] volume`) times the server's
  `volume` times `master_volume`, each as a percent.
- A rule with `sound = "none"` and `banner = "off"` drops the message, except a
  personal @-mention.
- Server list changes need a restart. A config that fails to parse keeps the
  old one and shows the problem in the menu.
- `[output] player` and `notifier` are still accepted but no longer used:
  sounds play through the system audio engine.

## Rule editor

Menubar, Edit rules…, or `z-iris edit`. Changes apply by themselves a moment
after you stop typing. Each save is validated with the same parser the app
uses, writes `config.toml.bak` first and keeps your comments; the running app
picks it up at once. Rules are listed by priority, with the defaults last as
"Default Rule"; deleted rules stay under Recently Deleted for five minutes.
Channel names come from every channel you can see, busiest first. The Sounds
pane plays every tone, adds your own (stored at the same loudness as the
bundled ones, the original kept in `sounds/originals/`) and removes them,
asking for a replacement when a rule uses one. Preview runs your last 1000
messages (and latest mentions) through the rules as edited, without saving.

## Scheduling

- Focus: `[focus] mode`, or an active quiet-hours window using `quiet_mode`.
  `mentions_and_dms` drops everything but DMs, group DMs and mentions; `silent`
  keeps banners but no sound or flash.
- `min_gap`: within the gap since the same rule (else conversation) last
  sounded, the banner shows but sound and flash are skipped.
- `batch_window`: the first message plays; later ones are held and become one
  silent summary banner such as "3 new in #ops".
- `summarize = true` (in `[defaults]` or a rule): that summary banner is
  rewritten a moment later as one sentence about what the held messages say,
  by Apple's on-device model ("Lunch at 11:45, pad thai with no peanuts;
  offsite moved to Thursday"). Nothing leaves the Mac. It needs Apple
  Intelligence turned on; without it, or if the model is slow, the plain
  summary stays.
- `repeat`, `repeat_every`, `repeat_boost`: extra sounds, each louder, until the
  message is read anywhere, deleted, the count runs out, or you pause.

## Conversations you're in

Post in a channel topic and you have joined it: from then on every message
there alerts, even with `notify_channel_messages = false` and through
`mentions_and_dms` focus and quiet hours, until the topic has been quiet for
`joined_hours` (default 48, up to 720). A personal @-mention joins its topic
too (`join_on_mention = false` turns that off), and so does any message
matched by a rule with `join = true`. Muted topics stay muted. z-iris reads
your last 200 messages when it connects, and remembers joined topics in
`~/Library/Application Support/z-iris/joined.json`, so they survive a restart;
a topic renamed or moved stays joined.

- A joined topic's message keeps the settings of the rule it matched (or
  `[defaults]`), stays on screen until read (`sticky`) and always shows a
  banner, even where its rule is silent; sound stays as that rule has it,
  at most once a minute per topic (`min_gap = 60`). A personal @-mention
  there is handled as a mention, as anywhere else.
- A `match = "conversation"` rule is layered on top: its settings win for
  joined topics it covers (its optional `channel`, `topic` regular expression
  and `server`), such as `sticky = false` or a sound of its own.
- `group_after` (default 3, 1 to 20; in `[defaults]` or a rule): the first
  alerts of a joined topic show one by one; past that many unread, they give
  way to one "5 new in #python > onboarding kristy" alert, updated as more
  arrive (with `summarize`, rewritten in a sentence) and cleared once the
  topic is read anywhere. A topic's alerts stack together in Notification
  Center.

## Reactions

Someone else's reaction to one of your messages shows a banner, without
sound: "Ada reacted 👍 to your message in #python > onboarding kristy", with
the start of your message below. Reactions to the same message within a
minute update one alert ("Ada and 2 others reacted 👍🎉"). Removing a
reaction, and your own reactions, never notify; reactions do not get through
focus, and they do not stay on screen, repeat or flash unless a reaction rule
says so. `[defaults] reactions = false` turns them off.

- A `match = "reaction"` rule gives reactions a sound and settings; `emoji =
  ["tada", "+1"]` (Zulip's emoji names, not their aliases) limits it to those, and `channel`,
  `topic` and `server` to reactions on messages there. A `[defaults] sound`
  never rings for reactions; a reaction rule's sound does.
- A channel, topic or conversation rule can carry its own reaction settings,
  for reactions on your messages in the places it covers:

      [[rule]]
      match = "channel"
      channel = "python"
      sound = "ping"

      [rule.reaction]
      sound = "soft"
      volume = 40

  Settings it leaves out come from its rule. It ranks as a reaction rule
  with its rule's priority. The editor shows it as "Reactions to Your Messages"
  on that rule.

## Sticky alerts

macOS banners fade after about 5 seconds. A rule with `stay = 30` keeps its
notification on screen for 30 seconds (1 to 3600), or until the message is
read; `sticky = true` keeps it until you deal with it. macOS sets the alert
style once per app, so these come from `z-iris-priority.app`
(`ca.toybox.z-iris.priority`), which z-iris runs beside it.

- Until you allow z-iris priority's notifications, sticky messages show as
  ordinary banners. Set its style to Persistent (z-iris warns if not).
- Clicking an alert opens the conversation, even after z-iris quit.
- An alert disappears when the message is read or deleted anywhere, including
  reads that happened while the Mac slept.
- Time-sensitive alerts need the priority profile (below).

## Sender faces

With development profiles, notifications show the sender's avatar as the main
icon with a small z-iris badge, as Messages does. A group DM shows a picture of
the sender and the other members' initials. Make (or renew) the profiles with
the paid team signed into Xcode; one project serves both:

    cd xcode/z-iris-priority
    xcodebuild -project z-iris-priority.xcodeproj -scheme z-iris-priority \
      -allowProvisioningUpdates -derivedDataPath /tmp/z-iris-xcb build
    xcodebuild -project z-iris-priority.xcodeproj -scheme z-iris-priority \
      -allowProvisioningUpdates -derivedDataPath /tmp/z-iris-xcb build \
      PRODUCT_BUNDLE_IDENTIFIER=ca.toybox.z-iris \
      CODE_SIGN_ENTITLEMENTS=z-iris-priority/z-iris.entitlements

then

    Z_IRIS_PROFILE=<z-iris profile> Z_IRIS_PRIORITY_PROFILE=<priority profile> \
    Z_IRIS_SIGN_IDENTITY=<certificate SHA-1> scripts/claude/build_app.sh

Profiles are in `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`.
The build refuses a profile with under 7 days left: an expired one stops the
app launching.

## Notification images and text

z-iris shows the first image in a message, else the sender's avatar. It
fetches only files on your Zulip server and avatars unless
`[output] external_images = true`, since another host would learn your address.
Credentials go only to your server's own scheme, host and port, and only for
uploads, avatars and thumbnails, re-checked on every redirect. Images are
cached under `~/Library/Caches/z-iris/media/` (50 MB).

Notifications show plain text: markdown is removed, links keep their text,
mentions read `@Name`, spoilers are hidden and emoji shortcodes become emoji.

## Sound loudness

Every sound is stored at the same loudness as you hear it, so 60% means the
same level for any of them: −13 LUFS over its loudest 400 ms (ITU-R BS.1770,
the measure behind EBU R 128), which counts high tones for more than low ones
and brief blips for less than held notes. A sound whose peak would clip stays
a little quieter. For files you dropped into the sounds folder by hand, run
`z-iris normalize` (`--no-backup` skips keeping originals); it is safe to run
twice.

## History

z-iris was first written in Python. The Swift version was checked against it
case by case: `swift/Tests/ZIrisCoreTests/Fixtures` holds what the Python
version did, and the tests hold the Swift version to it. The Python code is in
git history.
