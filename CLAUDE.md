# z-iris

macOS menubar notifier for Zulip. Design: `docs/design.md`. Plans: `docs/plan-phase-1.md`, `docs/plan-phase-2.md`.

## Commands

- Install: `uv sync --python /opt/homebrew/opt/python@3.13/bin/python3.13` (the app bundle needs Homebrew's 3.13)
- App bundle: `scripts/claude/build_app.sh [dest.app]`; icons: `scripts/claude/make_icon.py`
- Zulip emoji names: `uv run python scripts/claude/make_zulip_emoji.py` (from `~/Devel/zulip-terminal`) regenerates `static/zulip_emoji.json`
- Test: `uv run pytest -q`
- Run: `uv run z-iris` (`--dry-run`, `--headless`, `--autoreload`, `probe`, `edit`)

## Constraints

- Sound plays through sox (`play`). Never `afplay` or macOS system sounds.
- Never use a shell to run a command. Message text is only an argv element.
- Never read, log or print zuliprc contents.
- Phase 2a: rules, sounds, volume, live reload. No repetition, intervals, batching or settings window yet.

## Gotchas

- The bundle's executable is `scripts/claude/launcher.c`, compiled against Homebrew's Python.framework. It must stay the running process (no exec of another binary) and be signed `-i ca.toybox.z-iris`, never `--deep`: otherwise macOS refuses notifications without prompting and lists the menubar item under its launcher.
- macOS never prompts for menubar icons: they are allowed in System Settings, Menu Bar (stored in group.com.apple.controlcenter `trackedApplications`). An app started by `uv run` is listed as `uv`. `scripts/claude/statusitem_probe.py` shows whether AppKit placed the item.

## Modules (src/z_iris)

config, rules, sounds, settings, engine, editing, preview, channels, loudness, plaintext, webui, reloader, message, narrow, mutes, policy, pipeline, output, notify (desktop-notifier backend, bundle only), visual, stream, media, menubar, __main__.
