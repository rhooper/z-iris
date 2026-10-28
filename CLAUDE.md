# z-iris

macOS menubar notifier for Zulip, in Swift (`swift/`, a SwiftPM package). The first version was Python; it is in git history. Plan: `~/.claude/plans/starry-petting-crescent.md`.

## Commands

- Test: `cd swift && swift test`
- Run from the checkout: `cd swift && swift run z-iris` (`--dry-run`, `--headless`, `probe`, `edit`, `normalize`, `flash`, `play`)
- Apps: `scripts/claude/build_app.sh [dest.app]` builds z-iris.app and z-iris-priority.app (default `~/Applications`); `Z_IRIS_SIGN_IDENTITY` (a certificate's SHA-1) with `Z_IRIS_PROFILE`/`Z_IRIS_PRIORITY_PROFILE` signs with entitlements, else ad hoc; `Z_IRIS_BUNDLE_ID` overrides z-iris's id
- Profiles: `xcodebuild -allowProvisioningUpdates` on `xcode/z-iris-priority/z-iris-priority.xcodeproj` makes or renews them (paid team R9MHS94TL4; README, Sender faces). That template app shares the priority bundle id, so afterwards unregister its DerivedData build (`lsregister -u`) or an alert click can launch it instead of the real helper
- Release: `scripts/claude/build_release.sh [out]` (default `dist/`): gets Developer ID profiles from Xcode's automatic signing (the `xcode/` template, archived and exported per bundle id; Xcode must be signed into team R9MHS94TL4), signs with the keychain identity they authorize, notarizes (notarytool profile `Z_IRIS_NOTARY_PROFILE`, default `z-iris-notary`), staples and checks with `syspolicy_check` and a real launch. Versions are semver from git tags (`scripts/claude/version.sh`): the release script picks the next one from the commits since the last tag and tags it; a commit that adds a feature carries a `Semver: minor` trailer, one that breaks configs or behaviour `Semver: major`, anything else is a patch. Published on GitHub as rhooper/z-iris (public, MIT); release zips go to GitHub Releases, never into git. A profile that names another certificate makes macOS kill the app at launch (POSIX 163)
- Tones: `scripts/claude/gen_tones.sh` (sox), `python3 scripts/claude/gen_dx7_tones.py` (`dx-*`), `gen_morse.py` (`sos`), `gen_moog.py` (`moog-a`), `gen_synths.py` (three each after nineteen famous synths), into `swift/Resources/sounds`, then `scripts/claude/level_sounds.sh` levels them all (−13 LUFS, `Loudness.swift`) and reports each; icons: `uv run scripts/claude/make_icon.py`
- Emoji: `python3 scripts/claude/make_zulip_emoji.py` (from `~/Devel/zulip-terminal`) then `uv run scripts/claude/dump_emoji.py` regenerates `swift/Sources/ZIrisCore/Resources/emoji.json`

## Constraints

- Never use a shell to run a command. Message text is only ever data.
- Never read, log or print zuliprc contents (`Credentials` never shows the key).
- Never `afplay` or macOS system sounds; sounds play through AVAudioEngine (`SoundPlayer`).

## Gotchas

- Behaviour is pinned by `swift/Tests/ZIrisCoreTests/Fixtures`: what the Python version did, frozen. A deliberate behaviour change updates the fixture by hand in the same commit. Python semantics reproduced on purpose: `pythonLowercased` (Final_Sigma), `pythonRepr` in config errors, `pythonOrder` (code point sort), round-half-even, Python whitespace for split/strip, `PyRegex` (rule patterns are Python `re` syntax on ICU; ICU's full case folding, ß ~ SS, is a known difference), `PyURL`/`pyURLJoin` (urlparse/urljoin) under the media credential rules. `TOMLSpans` writes tomlkit's bytes (editing fixtures are byte-exact).
- TOMLDecoder 0.4.5 crashes on non-contiguous strings: call `makeContiguousUTF8()` first.
- Never use a top-level `await` in an executable's `main.swift`: it makes an async main whose `app.run()` blocks the main queue, so main-actor tasks and `DispatchQueue.main` work (menu updates, flashes, clicks) never run; async commands go through `command { }` (a Task plus `dispatchMain`).
- UserNotifications only works inside an app bundle (a bare binary throws "bundleProxyForCurrentProcess is nil"); test the helper and banners from a built bundle.
- z-iris-priority.app (`ca.toybox.z-iris.priority`, `ZIrisPriority`) shows sticky alerts; z-iris runs it as a child and talks JSON lines over stdin/stdout (`PriorityLink`, `PriorityService`). It stays a sibling app (`docs/swift-macos-spikes.md`). macOS only prompts it for permission from a real location (`~/Applications`), never `/tmp`, and Persistent is a style the user sets. Ad hoc signing cannot carry the time-sensitive or communication entitlement (macOS kills the app); profiles from the paid team can. An expired profile stops the app launching. Design: `docs/superpowers/specs/2026-10-19-sticky-alerts-design.md`.
- Sender faces: communication notifications (`Comms.swift`), needing the communication entitlement and `NSUserActivityTypes` = INSendMessageIntent. For one person macOS shows `INPerson.displayName` as the title, so it is the whole title; a group shows sender + group name and needs the picture z-iris draws. `setImage(_:forParameterNamed:)` is called by selector (Swift marks it unavailable on macOS). Proven calls: `docs/sender-icons-spike.md`.
- macOS never prompts for menubar icons: they are allowed in System Settings, Menu Bar.

## Layout (swift/)

ZIrisCore (no AppKit: config, rules, engine, pipeline, editing, text, media URL rules), ZulipKit (zuliprc, REST client, EventStream, MediaFetcher, editor's channel and preview sources), ZIrisMac (AppKit/UserNotifications/AVFoundation: output, banners, comms, priority link and service, sound, flash, menubar, editor), ZIrisApp (`z-iris`), ZIrisPriority (`z-iris-priority`); assets in `swift/Resources`.
