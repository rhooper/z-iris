# z-iris

A macOS menubar app that streams your Zulip messages and tells you about the
ones that matter, with your own sounds. Named after Iris, the Greek messenger
of the gods.

- **Rules** pick the sound, volume, banner and screen flash per channel (names
  or patterns), topic, keyword, mention, DM or group DM, edited in a local web
  editor that keeps your config file's comments.
- **Notifications show the sender's face**, can stay on screen for a set time or
  until read, and disappear when you read the message elsewhere.
- **Sounds**: built-in tones, Yamaha DX7- and Minimoog-style synth voices, Morse
  SOS, public-domain recordings (see `src/z_iris/sounds/SOURCES.md`), or your own.
- **Repeats, batching, focus and quiet hours** keep busy channels in check.
- Clicking a notification opens the conversation in Zulip Desktop.

macOS on Apple silicon. MIT licensed.

## Install

1. Download `z-iris-<version>-macos-arm64.zip` from the
   [releases](https://github.com/rhooper/z-iris/releases) and move both apps,
   `z-iris.app` and `z-iris-priority.app`, to `~/Applications` (or
   `/Applications`). Keep them side by side; z-iris priority shows the alerts
   that stay on screen.
2. Install sox, which plays the sounds: `brew install sox`.
3. Create `~/.config/z-iris/config.toml` from
   [`config.example.toml`](config.example.toml), pointing `zuliprc` at a
   zuliprc file for your Zulip account (Zulip: Settings, Account & privacy, API
   key, download zuliprc).
4. Open z-iris. Allow its notifications when macOS asks, and allow z-iris
   priority's the first time a sticky alert appears. In System Settings,
   Notifications, z-iris priority, choose Persistent.
5. Turn off Zulip's own desktop notifications and sounds so nothing is doubled.

Clicking a notification opens a `zulip://` link, which needs a Zulip Desktop
build with `zulip://` support (not yet in an official release).

## Build from source

```sh
brew install sox
uv sync --python /opt/homebrew/opt/python@3.13/bin/python3.13
uv run pytest -q
scripts/claude/build_app.sh       # development apps in ~/Applications, using this checkout
scripts/claude/build_release.sh   # self-contained, signable apps in ./dist
```

`build_release.sh` signs ad hoc unless `Z_IRIS_SIGN_IDENTITY` names a Developer
ID certificate; see the script's header for notarization and the provisioning
profiles that enable sender faces and time-sensitive alerts.

## Use

```sh
uv run z-iris              # menubar app
uv run z-iris --dry-run    # print what would notify; play nothing
uv run z-iris --headless   # stream without the menubar
uv run z-iris probe        # check the server connection and response shape
```

## What notifies by default

- Direct messages and group DMs.
- Personal @-mentions, wildcard mentions and your alert words.
- Optionally every unmuted channel message (`notify_channel_messages = true`).
- Never your own messages. Muted channels and topics are respected, except for
  a personal @-mention, which still notifies.

## Verified against a real server

`z-iris probe` against a current Zulip server returns `subscriptions` and
`user_topics` (with `visibility_policy`), so muted topics use the modern shape.
The register response does not include your user id, so z-iris asks for your
profile separately. The legacy `muted_topics` shape is handled but untested
against a real server.

## Banners and the app bundle

macOS only lets an app bundle post native notifications, so z-iris runs as its
own bundle, `~/Applications/z-iris.app` (id `ca.toybox.z-iris`, no Dock icon).
`scripts/claude/build_app.sh [dest.app]` builds it: a small native launcher
(`scripts/claude/launcher.c`) that embeds Homebrew's Python and runs `-m z_iris`
with this checkout's `src` and `.venv`. It also builds `z-iris-priority.app` next
to it (see Sticky alerts). Rebuild after `brew upgrade python@3.13` or if you
move the checkout. Start it with
`~/Applications/z-iris.app/Contents/MacOS/z-iris` (same arguments as `uv run z-iris`).

The first banner asks "z-iris would like to send you notifications": click Allow.
Banners carry the sender's avatar when an image resolver is wired in, and clicking
one opens a `zulip://<host>/#narrow/...` link (needs a Zulip Desktop build with
`zulip://` support, the `feat/zulip-url-handler` branch of zulip-desktop).

Outside the bundle (`uv run z-iris`) or if notifications are not allowed, z-iris
prints one line on stderr and falls back to terminal-notifier, so banners never
vanish. `[output] notifier` is ignored. `scripts/claude/make_icon.py` regenerates
the icons in `src/z_iris/static/`.

Notification images: z-iris shows the first image in a message, else the sender's
avatar. By default it fetches only files on your Zulip server (uploads,
thumbnails, avatars) and Gravatar avatars. Fetching an image from any other host
tells that host your IP address and that you are online, so it is off unless you
set `[output] external_images = true`. Sender avatars are always fetched (without
credentials) from wherever the server says they live, such as its S3 storage or
Gravatar: the server chooses that URL, not the sender. Credentials are only sent to your server
over its own scheme, host and port, and only for `/user_uploads/`,
`/user_avatars/` and `/thumbnail` paths.

## Sticky alerts

macOS banners fade after about 5 seconds, and apps cannot change that. A rule
with `stay = 30` keeps its notification on screen for 30 seconds (1 to 3600),
then removes it, or sooner if you read the message. A rule with
`sticky = true` (or `sticky = true` in `[defaults]`) keeps its
notification on screen until you deal with it, for messages you must not miss
while away, such as DMs. macOS sets banners or persistent alerts once per app, so
these come from a second app, `~/Applications/z-iris-priority.app`
(id `ca.toybox.z-iris.priority`), built by `build_app.sh` beside z-iris.

- The first sticky alert asks "z-iris priority would like to send you
  notifications": click Allow. Until you answer, sticky messages show as
  ordinary banners. In System Settings, Notifications, z-iris
  priority, the alert style should be Persistent (z-iris logs a warning if not).
  Turn off Summarize notifications there so they are never held back.
- Clicking an alert opens the conversation in Zulip, even after z-iris quit.
- An alert disappears by itself when the message is read or deleted anywhere.
  After the Mac sleeps and z-iris reconnects, it checks the server's unread list
  and clears alerts for anything read meanwhile.
- z-iris still plays the sound, flash and repeats; Pause and `[focus]` apply as
  for any rule. If z-iris priority is missing, refused or stuck, the message is
  shown as an ordinary banner instead.
- macOS only offers the permission prompt to the app in a real location such as
  `~/Applications`, not a temporary folder.
- Time-sensitive alerts (through Focus and summaries) need a development profile:
  `Z_IRIS_PRIORITY_PROFILE=<profile> Z_IRIS_SIGN_IDENTITY="<identity>"
  scripts/claude/build_app.sh`. Without one, the alerts are ordinary persistent
  alerts. The profile comes from Xcode with a paid team (a Personal Team does
  not offer Time Sensitive Notifications): open
  `xcode/z-iris-priority/z-iris-priority.xcodeproj` (bundle id
  `ca.toybox.z-iris.priority`, Time Sensitive and Communication Notifications;
  it exists only to make the profile) and build once; the profile appears in
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`. Use a
  certificate's SHA-1 (`security find-identity -v -p codesigning`) as the
  identity when two share a name. z-iris warns 2 days before the profile
  expires.

## Sender faces

With a development profile, notifications show the sender's avatar as the main
icon with a small z-iris badge, as Messages does (macOS "communication
notifications"). Titles read as before. A group DM shows a group picture: the
sender's avatar and the other members' initials. A picture in the message is
the thumbnail on the right; the avatar is never shown twice. A batch summary, a
sender without a fetchable avatar, or a build without the entitlement gets the
plain notification (z-iris logs once why).

Both apps need the Communication Notifications capability from a paid team.
Make (or renew) their profiles from the command line, signed into the team in
Xcode's settings; one project serves both:

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
The build refuses a profile with under 7 days left, since an expired one stops
the app launching; z-iris warns from 14 days before.

## Rules and volume

Rules live in `~/.config/z-iris/config.toml` as `[[rule]]` tables, and the file
reloads while z-iris runs (menubar: Reload config). `config.example.toml` has
one sample per kind.

- `match`: `channel`, `topic`, `keyword`, `mention`, `wildcard`, `alert_word`, `dm` or `group_dm`. `mention` is @you only and `wildcard` is @all, @everyone, @channel or @topic;
  `alert_word` is your own Zulip alert words, which the server flags separately.
  Topic and keyword values are case-insensitive regular expressions.
- `description`: optional text shown in the editor, logs and the dry run; without
  one a rule is shown by what it matches ("Channel #ops, #deploys"). Older
  configs' `name` is read as the description.
- `channel`: one channel or a list, `channel = ["ops", "infra-.*"]`. Each entry is
  a case-insensitive regular expression for the whole channel name, so `ops` is
  exactly #ops and `ops-.*` matches #ops-east and #ops-west.
- The editor keeps rules sorted by priority, then description, and shows the
  defaults as the last rule, "Default — everything else". Volume is a rule's
  volume (the default's when it sets none) times the master volume; a server
  volume shared by every server is folded into the master when the editor saves.
- `sound`: a sound name or `none`. Names are the bundled tones (chime, ping,
  bell, blip, knock, double, triple, rise, fall, alert, urgent, low, soft, mid-short
  and mid-long (200 and 350 ms of middle C), the
  Yamaha DX7-style FM tones `dx-*` after its factory presets: epiano, piano-c,
  bells, marimba, bass, brass, vibe, koto, clav, harpsichord, steel-drum, flute,
  organ, strings, orch-chime, synlead; moog-a: a Minimoog-style A4 eighth note; and sos: SOS in Morse on a
  1910s spark-gap wireless note; plus eleven public-domain recordings: bicycle-bell,
  church-bells, cowbell, doorbell, foghorn, gong, rooster, singing-bowl, steam-whistle,
  typewriter-ding, wind-chimes, with sources in `src/z_iris/sounds/SOURCES.md`) and
  any file in `~/.config/z-iris/sounds/` (the file name without its extension).
  Add your own in the editor, or drop a file in that folder. Older configs
  that give a file path still work. `volume`: 0 to 100.
  `banner`: `full`, `title` (no message text) or `off`. `server`: one server.
- Precedence: higher `priority` first, then topic, keyword, mention, wildcard, alert word, channel,
  group DM, DM, then file order.
- Final volume is rule volume (or `[defaults] volume`) times the server's
  `volume` times `master_volume`, each as a percent.
- A rule never overrides your own messages or muted topics. A personal
  @-mention in a muted topic still notifies.
- A rule with `sound = "none"` and `banner = "off"` drops the message.
- Server list changes need a restart. A config that fails to parse keeps the
  old one and shows the problem in the menu.

## Notification images

`media.ImageResolver.image_for(message)` returns a local PNG for a notification
attachment: the first image in the message (markdown image, bare image link, or a
`/user_uploads/` link), else the sender's avatar, else nothing. Images are fetched with
short timeouts and size caps, converted with `sips` to at most 512px (avatars 256px) and
cached under `~/Library/Caches/z-iris/media/` (50 MB, oldest evicted). Zulip credentials
are sent only to the Zulip server's own host, never to external image hosts.
## Scheduling (engine)

`engine.py` sits between the pipeline and the output and applies, per notification:

- Focus: `[focus] mode` (or an active quiet-hours window, using `quiet_mode`). An explicit
  mode beats quiet hours. `mentions_and_dms` drops everything but DMs, group DMs and
  personal or wildcard mentions. `silent` keeps banners but no sound or flash.
- `min_gap`: inside the gap since the last sound for the same rule (else same
  channel/topic or DM), the banner shows but sound and flash are skipped.
- `batch_window`: the first message plays; later ones for the same key are held and
  become one silent summary banner such as "3 new in #ops" when the window ends.
- `repeat`, `repeat_every`, `repeat_boost`: extra sounds, each louder, until the message
  is read in any client, deleted, the count runs out, or you pause.

`--dry-run` prints each engine decision.

## Roadmap

Phase 3: repetition, intervals, intensity,
batching and focus modes. See `docs/design.md`.

## Rule editor

Menubar, Edit rules…, or `uv run z-iris edit`. It opens a page served on
127.0.0.1 only, behind a random token in the URL. Changes apply by themselves a moment after you stop typing (there is no Save button). Each save is validated with the same
parser the app uses, writes `config.toml.bak` first, keeps your comments, and
the running app picks the change up at once. zuliprc paths are never sent to
the page. Each rule has an On switch. Deleted rules wait in a collapsed list at the bottom for five minutes, where you can restore or discard them. Channel names autocomplete from your subscriptions. Sounds are chosen from a menu, and Add sound uploads a file into the sounds
folder; a name that already exists (yours or a bundled tone, any case) is refused. The Sounds section lists every bundled tone with Play, and your sounds with Play and Remove; removing one that the default or a rule uses asks which sound to use instead and switches them over. Test plays a sound through sox at the
volume shown. Rule cards collapse to one line (Collapse all / Expand all) and show "Plays at N%": rule or default volume x server volume x master volume. Each rule and the defaults card also set the desktop notification, flash (with Test flash), repeat, minimum gap and batch window. A Focus card sets focus mode and quiet hours.

Preview against recent messages fetches your last 1000 messages (Fetch 1000 older pages further back, up to 10,000) (read-only,
through the zulip client and your zuliprc) and runs them through the rules on
the page, saved or not. Each rule shows the messages that use it and the sound
and volume they would get. Other messages are summarised by reason (muted, own
message, no rule). Nothing is saved and nothing plays.

## Development: autoreload

`uv run z-iris --autoreload` (combine with `--dry-run`, `--headless` or `edit`)
runs z-iris as a child process and restarts it when any `.py` or `.html` file
in `src/z_iris` changes. If the app crashes it waits for the next edit, so
fixing the code brings it back. Choosing Quit in the menu ends the run. Config
changes never need this: the config file reloads by itself.

## Sound loudness

Every sound is stored at the same loudness, so 60% means the same level for a
bell, a knock or a file you added. Bundled tones are generated normalized
(`scripts/claude/gen_tones.sh`). Sounds you add in the editor are converted to a
normalized 16-bit wav, and the file as you uploaded it is kept in
`~/.config/z-iris/sounds/originals/`. For files you dropped into the sounds
folder by hand, run `uv run z-iris normalize` (`--no-backup` skips keeping
originals). It is safe to run twice. The target is an RMS level, capped so the
peak never clips, so a very peaky sound can end up quieter than the rest.

## Notification text

macOS notifications show plain text only (no bold, links or other formatting),
so z-iris converts the Zulip markdown first: markers are removed, links keep
their text, mentions read `@Name`, channel links read `#channel > topic`,
images and uploads get a 🖼 or 📎 marker, spoiler text is never shown, and
emoji shortcodes such as `:tada:` become real emoji, which the notification
font (Apple Color Emoji) can draw. Custom realm emoji have no Unicode form and
stay as `:name:`.
## Screen flash

A rule or `[defaults]` can set `flash` to `screen`, `top`, `bottom`, `left` or `right`, with
`flash_color` (`#rrggbb`) and `flash_seconds`. The overlay covers every screen, ignores the
mouse and fades out. Try one without waiting for a message:

    uv run z-iris flash top --color '#0066ff' --seconds 1
