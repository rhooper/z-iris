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
- No settings window: rules are edited in the web editor (`edit`) or the config file.

## Gotchas

- The bundle's executable is `scripts/claude/launcher.c`, compiled against Homebrew's Python.framework. It must stay the running process (no exec of another binary) and be signed `-i ca.toybox.z-iris`, never `--deep`: otherwise macOS refuses notifications without prompting and lists the menubar item under its launcher.
- z-iris-priority.app (`ca.toybox.z-iris.priority`, module `priority`) shows sticky alerts; z-iris talks to it over stdin/stdout JSON lines (`prioritylink`). macOS only prompts it for notification permission when the bundle is in a real location (`~/Applications`), never `/tmp`. Ad hoc signing cannot carry the time-sensitive entitlement (macOS kills the app); that needs a development profile from the paid team R9MHS94TL4 (`Z_IRIS_PRIORITY_PROFILE`, `Z_IRIS_SIGN_IDENTITY` as a SHA-1; see README, Sticky alerts). Rebuilding without them drops time-sensitive. Design: `docs/superpowers/specs/2026-10-19-sticky-alerts-design.md`.
- macOS never prompts for menubar icons: they are allowed in System Settings, Menu Bar (stored in group.com.apple.controlcenter `trackedApplications`). An app started by `uv run` is listed as `uv`. `scripts/claude/statusitem_probe.py` shows whether AppKit placed the item.

## Modules (src/z_iris)

config, rules, sounds, settings, engine, editing, preview, channels, loudness, plaintext, webui, reloader, message, narrow, mutes, policy, pipeline, output, notify (desktop-notifier backend, bundle only), priority (z-iris-priority.app's alert service), prioritylink (z-iris side of the sticky handoff), visual, stream, media, menubar, __main__.
