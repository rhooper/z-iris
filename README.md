# z-iris

A macOS menubar app that streams your Zulip messages and notifies you with
custom sounds. Named after Iris, the Greek messenger of the gods.

Phase 1 (this version): streams one or more servers, shows a banner and plays
a sound for DMs and mentions, and opens the right chat in Zulip Desktop when
you click the banner. See `docs/design.md` for the roadmap.

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

## Roadmap

Phase 2: custom sounds and per-rule volume, rule kinds (channel, topic, keyword,
mention, DM, group DM), and a settings window. Phase 3: repetition, intervals,
intensity, batching and focus modes. See `docs/design.md`.
