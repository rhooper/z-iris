# z-iris

macOS menubar notifier for Zulip. Design: `docs/design.md`. Plans: `docs/plan-phase-1.md`, `docs/plan-phase-2.md`.

## Commands

- Install: `uv sync --python /opt/homebrew/opt/python@3.13/bin/python3.13` (the app bundle needs Homebrew's 3.13)
- Tones: `scripts/claude/gen_tones.sh` (sox), `scripts/claude/gen_dx7_tones.py` (FM, DX7-style `dx-*`) `scripts/claude/gen_morse.py` (`sos`) and `scripts/claude/gen_moog.py` (`moog-a`)
- App bundle: `scripts/claude/build_app.sh [dest.app]`; icons: `scripts/claude/make_icon.py`
- Release: `scripts/claude/build_release.sh [out]` builds self-contained apps (uv's standalone Python 3.13 inside) into `dist/` and zips them; `Z_IRIS_SIGN_IDENTITY` (Developer ID), `Z_IRIS_PROFILE`/`Z_IRIS_PRIORITY_PROFILE` (Developer ID profiles), `Z_IRIS_NOTARY_PROFILE` (notarytool). Published on GitHub as rhooper/z-iris (public, MIT); release zips go to GitHub Releases, never into git. The Developer ID profiles must authorize the certificate `Z_IRIS_SIGN_IDENTITY` names, or macOS kills the notarized app at launch (POSIX 163); check with `syspolicy_check distribution dist/z-iris.app` and a real launch before publishing
- Profiles: `xcodebuild -allowProvisioningUpdates` on `xcode/z-iris-priority/z-iris-priority.xcodeproj` makes or renews them (paid team R9MHS94TL4). That template app shares the priority bundle id, so afterwards unregister its DerivedData build (`lsregister -u`) or an alert click can launch it instead of the real helper; for z-iris.app add `PRODUCT_BUNDLE_IDENTIFIER=ca.toybox.z-iris CODE_SIGN_ENTITLEMENTS=z-iris-priority/z-iris.entitlements` (README, Sender faces)
- Zulip emoji names: `uv run python scripts/claude/make_zulip_emoji.py` (from `~/Devel/zulip-terminal`) regenerates `static/zulip_emoji.json`
- Test: `uv run pytest -q`; Swift port: `cd swift && swift test`; Swift app: `cd swift && swift run z-iris` (same commands as the Python one, plus `play`); bundle: `scripts/claude/build_swift_app.sh` (`Z_IRIS_SOUNDS` overrides where the bundled tones are)
- Swift parity fixtures: `uv run python scripts/claude/gen_fixtures.py` (Python runs synthetic cases into `swift/Tests/ZIrisCoreTests/Fixtures`), `scripts/claude/dump_emoji.py` (emoji table); `scripts/claude/check_fixtures.sh` fails if either is stale
- Run: `uv run z-iris` (`--dry-run`, `--headless`, `--autoreload`, `probe`, `edit`)

## Constraints

- Sound plays through sox (`play`). Never `afplay` or macOS system sounds.
- Never use a shell to run a command. Message text is only an argv element.
- Never read, log or print zuliprc contents.
- No settings window: rules are edited in the web editor (`edit`) or the config file.

## Gotchas

- Swift port (`swift/`, plan `~/.claude/plans/starry-petting-crescent.md`): ZIrisCore must behave exactly as the Python modules. A Python behaviour change regenerates the fixtures in the same commit. Python semantics that Swift does not give for free and are reproduced on purpose: `pythonLowercased` (Final_Sigma), `pythonRepr` in config errors, `pythonOrder` (code point sort), round-half-even, Python whitespace for split/strip, `PyRegex` (Python `re` syntax on ICU; ICU's full case folding, ß ~ SS, is a known difference). TOMLDecoder crashes on non-contiguous strings: call `makeContiguousUTF8()` first. `TOMLSpans` must keep writing tomlkit's bytes (editing fixtures are byte-exact). ZulipKit repeats the Python zulip client on the wire (zuliprc precedence, base_url, retries) and media.py's credential rules on top of `PyURL`/`pyURLJoin` (Python's urlparse/urljoin); the Python client has no `get_file_temporary_url`, so uploads use basic auth in both. Never use a top-level `await` in the app's `main.swift`: it makes an async main whose `app.run()` blocks the main queue, so main-actor tasks and `DispatchQueue.main` work (menu updates, flashes, clicks) never run; async commands go through `command { }` (a Task plus `dispatchMain`).
- The bundle's executable is `scripts/claude/launcher.c`, compiled against Homebrew's Python.framework. It must stay the running process (no exec of another binary) and be signed `-i ca.toybox.z-iris`, never `--deep`: otherwise macOS refuses notifications without prompting and lists the menubar item under its launcher.
- z-iris-priority.app (`ca.toybox.z-iris.priority`, module `priority`) shows sticky alerts; z-iris talks to it over stdin/stdout JSON lines (`prioritylink`). macOS only prompts it for notification permission when the bundle is in a real location (`~/Applications`), never `/tmp`. Ad hoc signing cannot carry the time-sensitive entitlement (macOS kills the app); that needs a development profile from the paid team R9MHS94TL4 (`Z_IRIS_PRIORITY_PROFILE`, `Z_IRIS_SIGN_IDENTITY` as a SHA-1; see README, Sticky alerts). Rebuilding without them drops time-sensitive. Design: `docs/superpowers/specs/2026-10-19-sticky-alerts-design.md`.
- Sender faces (`sender`, `comms`): communication notifications built with rubicon (desktop-notifier cannot), needing the communication entitlement and `NSUserActivityTypes` = INSendMessageIntent. For one person macOS shows `INPerson.displayName` as the title, so it is today's whole title; a group shows sender + group name and needs a picture z-iris draws (macOS draws none). Proven calls: `docs/sender-icons-spike.md`. Both apps sign with profiles (`Z_IRIS_PROFILE`, `Z_IRIS_PRIORITY_PROFILE`); an expired profile stops the app launching.
- macOS never prompts for menubar icons: they are allowed in System Settings, Menu Bar (stored in group.com.apple.controlcenter `trackedApplications`). An app started by `uv run` is listed as `uv`. `scripts/claude/statusitem_probe.py` shows whether AppKit placed the item.

## Modules (src/z_iris)

config, rules, sounds, settings, engine, editing, preview, channels, loudness, plaintext, webui, reloader, message, narrow, mutes, policy, pipeline, output, notify (desktop-notifier backend, bundle only), sender (who a notification is from), comms (communication notifications and group pictures), priority (z-iris-priority.app's alert service), prioritylink (z-iris side of the sticky handoff), visual, stream, media, menubar, __main__.
