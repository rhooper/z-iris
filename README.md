# z-iris

A macOS menubar app that streams your Zulip messages and notifies you with
custom sounds. Named after Iris, the Greek messenger of the gods.

Phase 1 and 2a (this version): streams one or more servers, shows a banner and plays
a sound for DMs and mentions, and opens the right chat in Zulip Desktop when
you click the banner. Rules set sound, volume and banner per channel, topic,
keyword, mention, DM or group DM. See `docs/design.md` for the roadmap.

## Setup

```sh
brew install sox terminal-notifier
uv sync --python 3.13
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

## Banner click-through

Banners use terminal-notifier 3.x, which needs notification permission. If a
banner never appears, z-iris prints `terminal-notifier exit 3` on stderr. Allow
it in System Settings, Notifications, terminal-notifier. Clicking a banner
opens a `zulip://<host>/#narrow/...` link, which needs a Zulip Desktop build
with `zulip://` support (the `feat/zulip-url-handler` branch of zulip-desktop).

## Rules and volume

Rules live in `~/.config/z-iris/config.toml` as `[[rule]]` tables, and the file
reloads while z-iris runs (menubar: Reload config). `config.example.toml` has
one sample per kind.

- `match`: `channel`, `topic`, `keyword`, `mention`, `dm` or `group_dm`.
  Topic and keyword values are case-insensitive regular expressions.
- `sound`: `synth`, `none` or a file sox can play. `volume`: 0 to 100.
  `banner`: `full`, `title` (no message text) or `off`. `server`: one server.
- Precedence: higher `priority` first, then topic, keyword, mention, channel,
  group DM, DM, then file order.
- Final volume is rule volume (or `[defaults] volume`) times the server's
  `volume` times `master_volume`, each as a percent.
- A rule never overrides your own messages or muted topics. A personal
  @-mention in a muted topic still notifies.
- A rule with `sound = "none"` and `banner = "off"` drops the message.
- Server list changes need a restart. A config that fails to parse keeps the
  old one and shows the problem in the menu.

## Roadmap

Phase 3: repetition, intervals, intensity,
batching and focus modes. See `docs/design.md`.

## Rule editor

Menubar, Edit rules…, or `uv run z-iris edit`. It opens a page served on
127.0.0.1 only, behind a random token in the URL. Saving validates with the same
parser the app uses, writes `config.toml.bak` first, keeps your comments, and
the running app picks the change up at once. zuliprc paths are never sent to
the page. Sound files are typed as paths. Test plays a sound through sox at the
volume shown.
