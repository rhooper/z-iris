# z-iris: visual alerts, native notifications, media, editor polish, phase 3

Written 2026-10-14. Base branch: `feat/phase-2b`. Five agents work in parallel,
each in its own git worktree and branch, on separate files. The lead merges.

## Shared rules (every agent)

- Python 3.12, `uv run pytest -q` must stay green. Test first (watch it fail), commit
  after each logical change with message ending
  `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Work ONLY in your worktree and only on the files your brief owns. If you need a
  change in a file you do not own, make the smallest possible hunk and name it in
  your report. Do not merge, rebase onto other branches, push or touch `main`.
- Never read, print or log zuliprc contents or credentials. Never use a shell to run
  a command built from message text (argv lists only). Sound plays through sox
  (`play`), never `afplay` or macOS system sounds.
- Do not run commands that make real sound or banners on the user's machine unless
  your brief says so. Use fakes in tests.
- Match the surrounding code style. Terse comments. Update `README.md` and
  `CLAUDE.md` module list for what you add (keep hunks small).
- Report: what you built, test count, anything unverified (especially anything
  that needs a human eye or ear), and files touched outside your ownership.

## Already in the base (the contract)

- `config.py`: rule/default settings `flash` (none|screen|top|bottom|left|right),
  `flash_color` (#rrggbb), `flash_seconds`, `repeat`, `repeat_every`, `repeat_boost`,
  `min_gap`, `batch_window`; `Config.focus` (`FocusConfig`: mode off|mentions_and_dms|silent,
  quiet_hours as minute pairs, quiet_mode). `resolve_action` returns `Action` with all of
  them resolved. `Rule.behaviour` holds per-rule overrides; `Config.behaviour` the defaults.
- `output.py`: `Output` has `deliver`, `banner`, `sound(notification, volume=None)`,
  `flash`. `RealOutput.visual` is a pluggable object with `flash(action)`.
- `Message.avatar_url`. `Notification(message, url, reason, action)`.
- Volume: final = rule volume (or `[defaults] volume`) x server volume x master volume.

## Agent 1: visual alerts (branch feat/visual-flash)

Owns: new `src/z_iris/visual.py`, `tests/test_visual.py`; small hunk in `__main__.py` or
`menubar.py` to install it as `output.visual` in menubar mode only.

Build the flash effect: for `action.flash` of screen, top, bottom, left or right, show a
click-through, borderless, non-activating overlay on EVERY screen, above all windows and
all Spaces/fullscreen apps, filled with `action.flash_color`, fading out over
`action.flash_seconds`. screen = full screen at partial alpha; bars are ~6% of the screen
edge, fully opaque at start. Use PyObjC/AppKit (NSWindow level above screen saver is not
needed; use `NSStatusWindowLevel+` with `NSWindowCollectionBehaviorCanJoinAllSpaces |
Stationary | FullScreenAuxiliary`, `setIgnoresMouseEvents_(True)`). All AppKit work must
run on the main thread (`PyObjCTools.AppHelper.callAfter`); `flash()` is called from stream
threads and must return immediately and never raise. Overlapping flashes must not leak
windows. Headless/dry-run: no-op.
Keep geometry and timing in pure functions (`frames(screen_rect, mode)`, fade curve) with
unit tests; the AppKit layer is thin. Add `z-iris flash <mode> [--color #hex] [--seconds N]`
CLI to fire a test flash for the user (starts a minimal NSApplication accessory app, shows
the flash, exits). Verify what you can without a human (window creation on main thread via a
short real run is fine; `screencapture -x` of a flash is a good check if it works).

## Agent 2: media (branch feat/media)

Owns: new `src/z_iris/media.py`, `tests/test_media.py`; a one-line hunk in `stream.py`
`_session` registering the client.

Build `ImageResolver`: `image_for(message) -> Path | None` returns a local file for the
notification attachment: the first image in the message content if there is one, else the
sender's avatar, else None. Never blocks long (hard timeouts, small size caps, content-type
check, only http/https). Details:
- Content is Zulip markdown (raw, not rendered). Find `![alt](url)` and bare links to
  image files (png jpg jpeg gif webp), and Zulip upload links `[name](/user_uploads/...)`
  with an image extension. Relative `/user_uploads/...` and `/thumbnail?...` URLs need the
  server's auth: fetch through the zulip client (basic auth from the client, never printed);
  use `client.get_file_temporary_url` if present, else an authenticated GET to base_url + path
  using `client.session`/requests with `(client.email, client.api_key)` taken from the client
  object only inside the HTTP call. Absolute external URLs: plain GET, no credentials, never
  send Zulip credentials to a non-Zulip host.
- Avatar: `message.avatar_url` may be absolute (gravatar/CDN), relative to the server, or None.
  Cache by URL hash under `~/Library/Caches/z-iris/media/` (injectable dir), LRU/size capped
  (e.g. 50 MB), convert/resize to a PNG at most 256px with `sips` (argv) or Pillow-free sox-free
  means; formats the notification centre cannot show (webp, svg) get converted or skipped.
- `ClientRegistry` (thread-safe): `set(server_name, client)`, `get(server_name)`; `stream.py`
  registers each session's client. `ImageResolver(registry, cache_dir, http_get=...)` with an
  injectable HTTP function so tests use no network.
- Tests: extraction of URLs from many content shapes, relative vs absolute, caching, size cap,
  timeouts, failure -> None, credentials never sent to foreign hosts.
Do not touch the banner code; agent 5 will call `image_for`.

## Agent 3: engine, phase 3 (branch feat/engine)

Owns: new `src/z_iris/engine.py`, `tests/test_engine.py`; edits to `stream.py` (route
notifications through the engine; read-awareness events) and `pipeline.py` only as needed.

Build the scheduler that sits between `Pipeline` and `Output` (spec section "High-volume
handling" in `~/Devel/zulip-desktop/docs/superpowers/specs/2026-10-13-custom-notification-sounds-design.md`
and `docs/design.md`). Pure logic with an injectable clock and timer so tests use a fake
clock. Behaviours, driven by the resolved `Action` fields and `config.focus`:
1. **Focus / quiet hours**: `focus.mode` or an active quiet-hours window (local time,
   windows may cross midnight) of `mentions_and_dms` lets only DMs, group DMs, personal
   mentions and wildcard mentions through with sound; others are dropped from sound (still a
   silent banner? no: dropped entirely); `silent` suppresses sound and flash but still shows
   banners. Rules cannot override focus except a personal @mention in `mentions_and_dms`.
2. **min_gap**: within `min_gap` seconds of the last SOUND for the same key (rule name, else
   channel/topic or DM), the banner still shows but sound and flash are skipped.
3. **batch_window**: first message plays normally; further messages with the same key within
   the window are held and delivered as ONE summary banner "N new in #channel" with no extra
   sound at window end (the banner click opens the latest message). Build the summary as a
   new Notification (title/body text for it must come from Notification fields; extend
   `Notification` minimally or add `summary: str | None`, coordinate via your report).
4. **repeat / repeat_every / repeat_boost**: after delivery schedule `repeat` extra sounds
   every `repeat_every` seconds, each louder by `repeat_boost` percentage points (cap 100),
   until the message is read, a limit, or pause. Read awareness: handle `update_message_flags`
   events (op add, flag read) and message `delete` events, cancelling pending repeats and
   removing queued batch items for those ids; the pipeline currently ignores non-message events
   except mutes, so pass them through.
5. Pause (existing `Controls.paused`) cancels pending repeats' sounds.
`Engine(output, settings, controls, clock, scheduler)`; `submit(notification)`;
`handle_event(server, event)`; `stop()`. Dry-run prints decisions via DryRunOutput.
Thread-safe; timers must not keep the process alive; exceptions in timers are logged to stderr
and never kill streaming. Integrate in `stream.py` and `__main__.py`.

## Agent 4: editor polish (branch feat/editor-ui)

Owns: `static/editor.html`, `webui.py`, `sounds.py`, `editing.py` (UI-facing parts), their tests.

1. **Rule collapsing**: each rule card collapses to a one-line summary (name, kind, sound,
   on/off); a collapse-all / expand-all control; state kept in sessionStorage (try/catch).
2. **"Fetch 1000 older"** button does not exist (not just disabled) until a preview has run.
3. **Sounds**: uploading a name that already exists (user sound OR bundled tone, compare
   case-insensitively) is rejected with a clear error and nothing is changed. Add deleting
   your own sounds: `DELETE`-style endpoint (POST `api/sounds/delete`), deletes the stored wav
   and its file in `sounds/originals/`; refuse (clear error naming the rules) if the sound is
   used by any rule or is the default sound; bundled tones cannot be deleted. UI: a
   "Your sounds" list with Delete buttons and confirmation, and Test.
4. **Fields for the new settings** in each rule card and the defaults card (grouped, with
   short help text): desktop notification (show/title only/off; this is the existing `banner`
   field, relabel it "Desktop notification"), flash (none, whole screen, top, bottom, left,
   right) with colour and duration and a **Test flash** button that calls a new endpoint
   `POST api/flash` which runs `z-iris flash` equivalent through an injectable callback
   (the endpoint just calls `EditorServer.flasher(action_dict)`, default no-op until the visual
   branch lands), repeat count/interval/boost, min gap, batch window. Plus a Focus card
   (mode, quiet hours list, quiet mode) which needs `focus` round-tripping in `editing.py`
   (read and write the `[focus]` table preserving comments; config parsing already exists).
5. **Volume clarity**: rename labels so the model is obvious: "Master volume (scales
   everything)", "Default rule volume (used when a rule sets none)", "Server <name> volume
   (scales only messages from <name>)". Show on each rule card a live read-out "Plays at N%"
   computed client-side as rule-or-default x server x master, with the formula in the tooltip,
   and a short explanation paragraph at the top of the volume card.
Verify in headless Chrome over the DevTools protocol as was done before (see the git history
of editor.html for the approach: Chrome at /Applications/Google Chrome.app, remote debugging
port, node 24 at ~/.nvm/versions/node/v24.19.0/bin/node); use a COPY of the config in a temp
dir, never `~/.config/z-iris`.

## Agent 5: native notifications and icon (branch feat/native-notifier)

Owns: new `src/z_iris/notify.py`, `src/z_iris/static/` icon assets, `scripts/claude/*` build
scripts, `pyproject.toml` deps, `output.py` banner code, `menubar.py` icon, tests.

The user wants a **Python package** for notifications instead of the terminal-notifier
binary. Use `desktop-notifier` (macOS backend uses UNUserNotificationCenter, supports an
attachment image, click callbacks, grouping/identifiers, `clear`).
Established facts (already tested by the lead):
- From a venv python it prints "Notification Center can only be used from an app bundle".
- Run from Homebrew's framework `Python.app` binary
  (`/opt/homebrew/opt/python@3.13/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python`)
  the bundle is recognised, but authorisation was denied (UNErrorDomain 1) because nothing
  has been allowed yet. So z-iris must run as its own app bundle with its own identity.
Deliverable:
1. `scripts/claude/build_app.sh` (+ a Python helper if easier) builds `~/Applications/z-iris.app`
   (path overridable): copy the Python.app interpreter into `Contents/MacOS/`, write
   `Info.plist` (CFBundleIdentifier `ca.toybox.z-iris`, name z-iris, `LSUIElement` true so no
   Dock icon, icon file), launcher that sets `PYTHONPATH` to the project venv site-packages
   and `src`, and runs `-m z_iris` with the user's args; ad-hoc `codesign -s -`. The venv must be
   built with the same Homebrew python@3.13 (document `uv sync --python /opt/homebrew/opt/python@3.13/bin/python3.13`
   or equivalent; pin it in the script). Verify the bundle starts, is recognised as a bundle
   (desktop-notifier no longer warns), and report exactly what the user must click (the first
   permission prompt). Do not click through system dialogs; do not grant permissions yourself.
2. `notify.py`: `Notifier` protocol (`show(title, body, url, image: Path|None, group, silent)`
   and `clear(group)`), `DesktopNotifier` implementation running its own asyncio loop on a
   daemon thread, click -> open the `zulip://` url with `open` (argv), no sound from the
   notification itself (sound stays with sox). Fall back, with one stderr line, to a
   `terminal-notifier` backend ONLY when not running inside a bundle or when the package
   reports no authorisation, so notifications never silently vanish; the fallback keeps
   the current `banner_command` code. Remove `terminal-notifier` as the default; `[output]
   notifier` stays accepted but ignored (warn once).
3. Banner modes `full` / `title` / `off` unchanged. Hook for images: `RealOutput.banner` calls
   an optional `image_for(message) -> Path | None` (injectable; agent 2 provides
   `media.ImageResolver.image_for`), passes the attachment if any. Text arguments keep the
   leading-character protections only where still needed for the fallback.
4. **Icon**: the Zulip logo (from `~/Devel/zulip-desktop/public/resources/Icon.png`, Apache
   licensed) with a quarter note on top. Generate with a script `scripts/claude/make_icon.py`
   (dev dependency Pillow via `uv add --dev pillow`; commit the produced PNGs and `.icns`
   built with `iconutil`). Use it as the app bundle icon and as the menubar icon (a template
   PNG that looks right at menubar size, light and dark; rumps `icon=` with `template=True`),
   keeping a text fallback if loading fails.
5. Tests with a fake notifier backend; no real banners in tests. Keep `uv run z-iris` working
   from the venv (fallback path) so development still works without the bundle.
