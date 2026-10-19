# z-iris

macOS menubar notifier for Zulip. Design: `docs/design.md`. Plans: `docs/plan-phase-1.md`, `docs/plan-phase-2.md`.

## Commands

- Install: `uv sync --python /opt/homebrew/opt/python@3.13/bin/python3.13` (the app bundle needs Homebrew's 3.13)
- App bundle: `scripts/claude/build_app.sh [dest.app]`; icons: `scripts/claude/make_icon.py`
- Test: `uv run pytest -q`
- Run: `uv run z-iris` (`--dry-run`, `--headless`, `--autoreload`, `probe`, `edit`)

## Constraints

- Sound plays through sox (`play`). Never `afplay` or macOS system sounds.
- Never use a shell to run a command. Message text is only an argv element.
- Never read, log or print zuliprc contents.
- Phase 2a: rules, sounds, volume, live reload. No repetition, intervals, batching or settings window yet.

## Gotchas

- The bundle's running process is the copied `Python`; it must be signed with `-i ca.toybox.z-iris` or macOS refuses notifications without prompting. Never `codesign --deep`.
- macOS never prompts for menubar icons: they are allowed in System Settings, Menu Bar. An app started by `uv run` is listed as `uv`. `scripts/claude/statusitem_probe.py` shows whether AppKit placed the item.

## Modules (src/z_iris)

config, rules, sounds, settings, engine, editing, preview, channels, loudness, plaintext, webui, reloader, message, narrow, mutes, policy, pipeline, output, notify (desktop-notifier backend, bundle only), visual, stream, media, menubar, __main__.
