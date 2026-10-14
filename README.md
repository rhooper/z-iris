# z-iris

A macOS menubar app that streams your Zulip messages and notifies you with
custom sounds. Named after Iris, the Greek messenger of the gods.

Phase 1 and 2a (this version): streams one or more servers, shows a banner and plays
a sound for DMs and mentions, and opens the right chat in Zulip Desktop when
you click the banner. Rules set sound, volume and banner per channel, topic,
keyword, mention, DM or group DM. See `docs/design.md` for the roadmap.

## Setup

```sh
brew install sox python@3.13 terminal-notifier
uv sync --python /opt/homebrew/opt/python@3.13/bin/python3.13
scripts/claude/build_app.sh     # builds ~/Applications/z-iris.app (native banners)
mkdir -p ~/.config/z-iris && cp config.example.toml ~/.config/z-iris/config.toml
```

Edit the config to point at your zuliprc. Turn off desktop notifications and
sounds in Zulip's own settings so nothing is doubled. Clicking a banner needs
Zulip Desktop with `zulip://` link support.

## Use

```sh
uv run z-iris              # menubar app
uv run z-iris --dry-run    # print what would notify; play nothing
uv run z-iris --headless   # stream without the menubar
uv run z-iris probe        # check the server connection and response shape
```

## What phase 1 notifies for

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
`scripts/claude/build_app.sh [dest.app]` builds it: a copy of Homebrew's
`Python.app` that runs `python -m z_iris` with this checkout's `src` and `.venv`.
Rebuild after `brew upgrade python@3.13` or if you move the checkout. Start it with
`~/Applications/z-iris.app/Contents/MacOS/z-iris` (same arguments as `uv run z-iris`).

The first banner asks "z-iris would like to send you notifications": click Allow.
Banners carry the sender's avatar when an image resolver is wired in, and clicking
one opens a `zulip://<host>/#narrow/...` link (needs a Zulip Desktop build with
`zulip://` support, the `feat/zulip-url-handler` branch of zulip-desktop).

Outside the bundle (`uv run z-iris`) or if notifications are not allowed, z-iris
prints one line on stderr and falls back to terminal-notifier, so banners never
vanish. `[output] notifier` is ignored. `scripts/claude/make_icon.py` regenerates
the icons in `src/z_iris/static/`.

## Rules and volume

Rules live in `~/.config/z-iris/config.toml` as `[[rule]]` tables, and the file
reloads while z-iris runs (menubar: Reload config). `config.example.toml` has
one sample per kind.

- `match`: `channel`, `topic`, `keyword`, `mention`, `wildcard`, `alert_word`, `dm` or `group_dm`. `mention` is @you only and `wildcard` is @all, @everyone, @channel or @topic;
  `alert_word` is your own Zulip alert words, which the server flags separately.
  Topic and keyword values are case-insensitive regular expressions.
- `sound`: a sound name or `none`. Names are the bundled tones (chime, ping,
  bell, blip, knock, double, triple, rise, fall, alert, urgent, low, soft) and
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
folder. Test plays a sound through sox at the
volume shown.

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
