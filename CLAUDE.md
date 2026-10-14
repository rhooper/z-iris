# z-iris

macOS menubar notifier for Zulip. Design: `docs/design.md`. Plans: `docs/plan-phase-1.md`, `docs/plan-phase-2.md`.

## Commands

- Install: `uv sync --python 3.13`
- Test: `uv run pytest -q`
- Run: `uv run z-iris` (`--dry-run`, `--headless`, `--autoreload`, `probe`, `edit`)

## Constraints

- Sound plays through sox (`play`). Never `afplay` or macOS system sounds.
- Never use a shell to run a command. Message text is only an argv element.
- Never read, log or print zuliprc contents.
- Phase 2a: rules, sounds, volume, live reload. No repetition, intervals, batching or settings window yet.

## Modules (src/z_iris)

config, rules, sounds, settings, engine, editing, preview, channels, loudness, plaintext, webui, reloader, message, narrow, mutes, policy, pipeline, output, stream, media, menubar, __main__.
