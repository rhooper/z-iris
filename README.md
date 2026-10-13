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
