# z-iris

macOS menubar notifier for Zulip. Design: `docs/design.md`. Plan: `docs/plan-phase-1.md`.

## Commands

- Install: `uv sync --python 3.13`
- Test: `uv run pytest -q`
- Run: `uv run z-iris` (`--dry-run`, `--headless`, `probe`)

## Constraints

- Sound plays through sox (`play`). Never `afplay` or macOS system sounds.
- Never use a shell to run a command. Message text is only an argv element.
- Never read, log or print zuliprc contents.
- Phase 1 only: no rules, per-rule sounds, repetition, intervals or batching.

## Modules (src/z_iris)

config, message, narrow, mutes, policy, pipeline, output, stream, menubar, __main__.
