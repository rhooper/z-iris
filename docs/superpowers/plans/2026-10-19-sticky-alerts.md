# Sticky Alerts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rules with `sticky = true` show persistent alerts from a second app, z-iris-priority.app, which disappear when the message is read anywhere.

**Architecture:** z-iris keeps sound, flash, repeats, focus and batching. For a sticky notification, `RealOutput` hands the banner to `PriorityNotifier`, which runs z-iris-priority's executable as a child and sends it one JSON request per line on stdin, reading one JSON reply per line. z-iris-priority (`z_iris.priority`) shows and clears alerts through desktop-notifier under its own bundle id with the Alerts style. Read events, deletions and post-reconnect unread checks become clear requests.

**Tech Stack:** Python 3.13 (Homebrew framework), desktop-notifier 6.2, PyObjC/AppKit, rumps, clang + codesign, pytest.

**Spec:** `docs/superpowers/specs/2026-10-19-sticky-alerts-design.md`

## Global Constraints

- Sound plays through sox (`play`). Never `afplay` or macOS system sounds.
- Never use a shell to run a command. Message text is only an argv element or JSON data.
- Never read, log or print zuliprc contents.
- A bundle's running process must be its own `CFBundleExecutable`, signed `-i <bundle id>`, never `--deep`.
- z-iris-priority: bundle id `ca.toybox.z-iris.priority`, display name `z-iris priority`, `LSUIElement` true, `NSUserNotificationAlertStyle` = `alert`, default path `~/Applications/z-iris-priority.app`.
- Banner group ids stay `banner_group(message)` = `f"z-iris-{server}-{id}"`.
- Focus (`[focus]`, quiet hours) and Pause apply to sticky rules unchanged; `banner = "off"` wins over `sticky`.
- Profile expiry warning threshold: 2 days.
- Tests: `uv run pytest -q`, all pass; new behaviour test-first. Never pipe pytest into another command when checking its result.
- Scripts live in `scripts/claude/`. Commits end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus

- `unread_msgs` missing from a register reply (old server, or `old_unreads_missing` set): reconcile must clear nothing, not everything. Test in Task 7.
- Server names that are prefixes of each other or contain regex characters (`w` and `w-2`, `a.b`): clearing one server's alerts must never touch another's. Test in Task 3.
- z-iris-priority hangs without replying: z-iris waits at most the reply timeout, then shows its own banner; the banner worker never blocks forever. Test in Task 5.
- Message text with newlines, quotes, emoji or a leading `-`: it reaches the alert unchanged and never splits a JSON line. Test in Task 5.
- A read event for a message never shown as sticky, or shown before a restart: a clear is still sent by group id and nothing fails. Test in Task 6.

---

### Task 1: Spikes — time-sensitive signing and child identity (throwaway)

**Files:**
- Create: `docs/priority-spike.md` (results; like `docs/native-notifier-spike.md`)
- Throwaway code under the session scratchpad only; nothing else committed.

- [ ] **Step 1: Child identity.** Copy `~/Applications/z-iris.app` to a scratch `z-iris-priority.app`, set `CFBundleIdentifier` to `ca.toybox.z-iris.priority`, add `NSUserNotificationAlertStyle` = `alert`, re-sign `codesign --force -s - -i ca.toybox.z-iris.priority`. Start its executable as a child of a running Python (`subprocess.Popen([exe, ...])`) with a one-off module that sends one desktop-notifier notification. Check: a permission prompt naming z-iris priority; its own entry in System Settings, Notifications; the alert stays until dismissed once style is Alerts. The user must look; say what to look for, then run `attention question`.
- [ ] **Step 2: Time-sensitive, ad-hoc.** Same scratch app plus an entitlements plist with `com.apple.developer.usernotifications.time-sensitive` = true, signed ad-hoc with `--entitlements`. Check: does it launch (no AMFI kill in `log show --last 2m --predicate 'process == "amfid"'`)? Does a Time Sensitive switch appear for it? Does a notification sent with `Urgency.Critical` arrive (and without the entitlement, is it still delivered, not refused)?
- [ ] **Step 3: Time-sensitive, Personal Team.** Only if Step 2 fails to launch or shows no switch. Identity `Apple Development: Rose  Hooper (W2W8Y49E9J)` (note the double space) is valid on rubik. The user creates a development profile for `ca.toybox.z-iris.priority` with Time Sensitive Notifications in Xcode (a throwaway macOS app project with that bundle id); copy it into the scratch app as `Contents/embedded.provisionprofile` and sign with that identity and the entitlements. Same checks.
- [ ] **Step 4: Record and report.** Write `docs/priority-spike.md` with each result. Tell the user, including the answer to "do I need to renew my developer account". If Step 1 failed (macOS treats the child as z-iris), stop: Task 4 and Task 5 must switch to launching with `open -g -a` and a Unix socket at `~/Library/Application Support/z-iris/priority.sock`; revise those tasks with the user before continuing. Record which signing mode Task 4 uses: `adhoc`, `adhoc+entitlement`, or `profile`.
- [ ] **Step 5: Commit** `docs/priority-spike.md` with message `docs: Record the z-iris-priority spikes.`

### Task 2: The `sticky` rule switch

**Files:**
- Modify: `src/z_iris/config.py` (BEHAVIOUR, a `_bool` check, `Action.sticky`)
- Modify: `src/z_iris/editing.py` (`RULE_FIELDS`, `DEFAULT_FIELDS`)
- Modify: `src/z_iris/static/editor.html` (`BUILTIN.sticky = false`; a checkbox in the "Desktop notification" section)
- Modify: `src/z_iris/output.py` (`DryRunOutput.deliver` wording)
- Modify: `config.example.toml` (document `sticky` beside `banner`)
- Test: `tests/test_config.py`, `tests/test_editing.py`, `tests/test_output.py`

**Interfaces:**
- Produces: `Action.sticky: bool` (default `False`, last field of `Action`); `BEHAVIOUR["sticky"] = (_bool, False)`; `_bool(value: object, label: str) -> bool` raising `ConfigError(f"{label} must be true or false")`.

- [ ] **Step 1: Write the failing tests**

```python
# tests/test_config.py
def test_sticky_is_a_rule_and_default_switch():
    config = parse_config(TOML_WITH_RULE + 'sticky = true\n')  # use the file's existing rule fixture style
    rule = config.rules[0]
    assert resolve_action(config, "work", rule).sticky is True
    assert resolve_action(config, "work", None).sticky is False

def test_sticky_must_be_a_boolean():
    with pytest.raises(ConfigError, match="sticky must be true or false"):
        parse_config(TOML_WITH_RULE + 'sticky = "yes"\n')

# tests/test_output.py
def test_dry_run_says_sticky(capsys):
    # an Action with sticky=True through DryRunOutput.deliver
    assert "sticky banner full" in capsys.readouterr().out
```

Add `"sticky"` round-trip coverage to the existing editing test that covers behaviour fields.

- [ ] **Step 2: Run** `uv run pytest -q tests/test_config.py tests/test_output.py tests/test_editing.py` — Expected: the new tests FAIL.
- [ ] **Step 3: Implement.** `_bool` beside `_choice`; `"sticky": (_bool, False)` in BEHAVIOUR; `sticky: bool = False` on `Action`. Dry run: `banner = "no banner" if off else f"{'sticky ' if action.sticky else ''}banner {action.banner}"`. Editor: checkbox labelled "Keep on screen until read (sticky)", help text "Shown by z-iris priority as an alert that stays until you click it, close it, or read the message elsewhere." Example config: `#   sticky: true keeps the notification on screen until read (needs z-iris-priority.app)`.
- [ ] **Step 4: Run** `uv run pytest -q` — Expected: all pass.
- [ ] **Step 5: Commit** `config: Add the sticky rule switch.`

### Task 3: The z-iris-priority service logic

**Files:**
- Create: `src/z_iris/priority.py` (service class now; app runtime in Task 4)
- Test: `tests/test_priority.py`

**Interfaces:**
- Produces, in `z_iris.priority`:
  - `class UrlStore` — `__init__(self, path: Path)`; `put(group: str, url: str) -> None`; `pop(group: str) -> str | None`; `drop(groups: Iterable[str]) -> None`. JSON file, written atomically (temp + `replace`), missing or corrupt file reads as empty. Default path `~/Library/Application Support/z-iris/priority-urls.json`.
  - `class PriorityService` — `__init__(self, notifier, urls: UrlStore, opener: Callable[[str], None] = notify.open_url)`; `async handle(request: dict) -> dict`; `clicked(group: str) -> None` (pop url, open it).
  - Requests (one JSON object per line) and replies:
    - `{"op": "status"}` → `{"ok": true, "allowed": bool, "style": "alert"|"banner"|"none"}`
    - `{"op": "show", "title": str, "body": str, "url": str, "group": str, "image": str|null}` → `{"ok": true}` or `{"ok": false, "reason": str}`
    - `{"op": "clear", "groups": [str]}` → `{"ok": true}`
    - `{"op": "clear_server", "server": str, "keep": [int]}` → `{"ok": true}`: clears every delivered alert whose id fully matches `z-iris-<re.escape(server)>-(\d+)` and whose number is not in `keep`.
    - Unknown op or malformed request → `{"ok": false, "reason": ...}`, never raises.
  - `notifier` is duck-typed: `async request_authorisation() -> bool`, `async send_notification(Notification) -> str`, `async clear(identifier) -> None`, `async get_current_notifications() -> list[str]`, plus `async alert_style() -> str` (Task 4 supplies the real one).

- [ ] **Step 1: Write the failing tests** with a `FakeNotifier` recording calls (async methods, configurable `allowed`, `style`, delivered ids):
  - `test_show_sends_a_time_sensitive_notification_with_the_group_as_identifier` — sent `Notification` has `identifier == "z-iris-work-7"`, `urgency == Urgency.Critical`, title/body unchanged (body `'-x "q"\nline2 🎉'`), and the url is stored under the group.
  - `test_show_when_not_allowed_replies_not_ok` — `{"ok": False, "reason": "not allowed"}`, nothing sent.
  - `test_clicked_opens_the_stored_url_once` — opener called with the url; a second click opens nothing.
  - `test_clear_removes_alerts_and_urls`.
  - `test_clear_server_keeps_unread_and_other_servers` — delivered `["z-iris-w-1", "z-iris-w-2", "z-iris-w-2-5", "z-iris-a.b-3", "z-iris-axb-4", "other"]`; `clear_server` for `"w"` keep `[2]` clears only `z-iris-w-1`; for `"a.b"` keep `[]` clears only `z-iris-a.b-3`.
  - `test_malformed_requests_reply_not_ok` — `{}`, `{"op": "show"}`, `{"op": "nope"}`.
  - `test_url_store_survives_restart_and_corruption` — new `UrlStore` on the same path sees earlier puts; a file containing `"{"` reads as empty.
- [ ] **Step 2: Run** `uv run pytest -q tests/test_priority.py` — Expected: FAIL (module missing).
- [ ] **Step 3: Implement** `UrlStore` and `PriorityService` in `src/z_iris/priority.py`. Image: `Attachment(path=Path(image))` when given and the file exists.
- [ ] **Step 4: Run** `uv run pytest -q` — Expected: all pass.
- [ ] **Step 5: Commit** `priority: Add the alert service for z-iris-priority.`

### Task 4: z-iris-priority.app — runtime and build

**Files:**
- Modify: `src/z_iris/priority.py` (add `main(argv: list[str] | None = None) -> int`, `if __name__ == "__main__"`)
- Modify: `scripts/claude/launcher.c` (module from `Z_IRIS_MODULE`)
- Modify: `scripts/claude/build_app.sh` (build both apps)
- Create: `scripts/claude/priority.entitlements` (only if Task 1 chose `adhoc+entitlement` or `profile`)
- Test: `tests/test_build_app.py`, `tests/test_priority.py`

**Interfaces:**
- Consumes: `PriorityService`, `UrlStore` (Task 3).
- Produces: `build_app.sh [dest.app]` builds `dest` and its sibling `z-iris-priority.app` in the same folder. Env: `Z_IRIS_SIGN_IDENTITY` and `Z_IRIS_PRIORITY_PROFILE` (path to a `.provisionprofile`) select profile signing for the priority app. The executable `z-iris-priority.app/Contents/MacOS/z-iris-priority` runs `-m z_iris.priority`.
- Produces in `z_iris.priority`: `serve(lines: Iterable[str], service: PriorityService, write: Callable[[str], None], run: Callable) -> None` — the stdin loop, pure enough to test: each line → `json.loads` → `service.handle` → `write(json.dumps(reply) + "\n")`; a bad line gets `{"ok": false, "reason": "bad json"}`.

- [ ] **Step 1: Write the failing tests**
  - `test_build_app.py::test_the_priority_app_is_built_beside_z_iris` — after `run(dest)`: `dest.parent / "z-iris-priority.app"` exists; its Info.plist (read with `plistlib`) has `CFBundleIdentifier == "ca.toybox.z-iris.priority"`, `CFBundleExecutable == "z-iris-priority"`, `NSUserNotificationAlertStyle == "alert"`, `LSUIElement is True`; `codesign -dv` shows `Identifier=ca.toybox.z-iris.priority`; its executable is Mach-O (`\xcf\xfa\xed\xfe`).
  - `test_priority.py::test_serve_answers_each_line_in_order` — lines `['{"op":"status"}', 'garbage']` produce two replies, the second `{"ok": false, "reason": "bad json"}`.
- [ ] **Step 2: Run** them — Expected: FAIL.
- [ ] **Step 3: Implement.**
  - `launcher.c`: `args[2] = Z_IRIS_MODULE;` with `#ifndef Z_IRIS_MODULE #define Z_IRIS_MODULE "z_iris" #endif`; the `-m` passthrough stays.
  - `build_app.sh`: factor a `build_bundle <dest> <id> <name> <executable> <module> <extra plist keys>` function; the main app unchanged; the priority app adds `<key>NSUserNotificationAlertStyle</key><string>alert</string>`. Sign per Task 1's mode: ad-hoc `-i ca.toybox.z-iris.priority` (plus `--entitlements` if chosen); with `Z_IRIS_PRIORITY_PROFILE` set, copy it to `Contents/embedded.provisionprofile` and sign with `-s "$Z_IRIS_SIGN_IDENTITY" --entitlements scripts/claude/priority.entitlements -i ca.toybox.z-iris.priority`.
  - `main()`: `NSApplication` accessory policy; desktop-notifier `DesktopNotifier(app_name="z-iris priority")` on its own asyncio loop thread (as `notify.DesktopNotifierBackend` does); `alert_style()` reads `UNUserNotificationCenter.currentNotificationCenter().getNotificationSettingsWithCompletionHandler_` → `alertStyle` 0/1/2 → `"none"`/`"banner"`/`"alert"`; set the notifier's app-level `on_clicked` to `service.clicked` (clicks after a relaunch arrive only with the identifier); a reader thread runs `serve` over `sys.stdin`. When stdin reaches EOF (z-iris quit, or macOS launched it to deliver a click), keep running 30 seconds after the last click, then `NSApp.terminate_(None)`.
- [ ] **Step 4: Run** `uv run pytest -q` — Expected: all pass.
- [ ] **Step 5: Manual check.** `scripts/claude/build_app.sh`; `printf '{"op":"status"}\n' | ~/Applications/z-iris-priority.app/Contents/MacOS/z-iris-priority` prints a status line. Then a `show` line with `"url": "zulip://…"`: the user approves the permission prompt, sets Alerts if needed, and confirms the alert stays and clicking opens Zulip (`attention question` first).
- [ ] **Step 6: Commit** `build_app: Build z-iris-priority.app beside z-iris.`

### Task 5: `PriorityNotifier` — the z-iris side of the handoff

**Files:**
- Create: `src/z_iris/prioritylink.py`
- Test: `tests/test_prioritylink.py`

**Interfaces:**
- Consumes: the request/reply shapes from Task 3; the executable path from Task 4.
- Produces in `z_iris.prioritylink`:
  - `PRIORITY_APP = Path.home() / "Applications" / "z-iris-priority.app"`; `executable(app: Path = PRIORITY_APP) -> Path`.
  - `class PriorityNotifier` — `__init__(self, fallback: Notifier, app: Path = PRIORITY_APP, start: Callable[[list[str]], Process] = _popen, warn: Callable[[str], None] = notify.log_problem, timeout: float = 2.0, clock=time.monotonic)`; `show(title, body, url, image=None, group=None, silent=True) -> None` (the `Notifier` shape); `clear(group: str) -> None`; `clear_server(server: str, keep: set[int]) -> None`. Thread-safe (one lock around a request and its reply).
  - `Process` is what `subprocess.Popen([exe], stdin=PIPE, stdout=PIPE, stderr=DEVNULL, text=True, bufsize=1)` returns; tests pass fakes with `stdin.write/flush`, `stdout.readline`, `poll()`.
  - `profile_days_left(app: Path, now: datetime) -> float | None` — `security cms -D -i <app>/Contents/embedded.provisionprofile` (argv), `plistlib.loads`, `ExpirationDate`; `None` when there is no profile or it cannot be read.
- Behaviour: start the child on first use; send `status` first and warn once if `allowed` is false or `style != "alert"` (text: `"z-iris priority alerts are set to <style>; set Alerts in System Settings, Notifications, z-iris priority"`); restart once per request if the child has exited; a missing executable, start failure, timeout (reply wait on a reader thread, bounded by `timeout`) or `{"ok": false}` → `fallback.show(...)` with the same arguments, plus one warning per change of state (as `DesktopNotifierBackend._transition` does). `clear`/`clear_server` failures are warned, not retried, with no fallback.

- [ ] **Step 1: Write the failing tests** with a `FakeChild` (scripted replies; can die, hang, or refuse):
  - `test_show_sends_one_json_line_and_text_arrives_intact` — body `'-x "q"\nline2 🎉'`: exactly one line written, `json.loads` of it gives the same body.
  - `test_refusal_falls_back_to_a_banner` — reply `{"ok": false, "reason": "not allowed"}` → fallback called once with the same title/body/url/group.
  - `test_a_hung_child_times_out_into_the_fallback` — child never replies; `timeout=0.05`; `show` returns within 1 second and the fallback shows the banner.
  - `test_a_dead_child_is_restarted_once` — first child's `poll()` returns 1; a second start is made; on a second failure, fallback.
  - `test_missing_app_falls_back_without_starting` — no executable → `start` never called, fallback shows.
  - `test_style_warning_once` — status `{"allowed": true, "style": "banner"}` → exactly one warning across two shows.
  - `test_clear_server_sends_keep_ids` — request `{"op": "clear_server", "server": "w", "keep": [2, 5]}` (sorted).
  - `test_profile_days_left_none_without_profile`.
- [ ] **Step 2: Run** `uv run pytest -q tests/test_prioritylink.py` — Expected: FAIL.
- [ ] **Step 3: Implement** `src/z_iris/prioritylink.py`.
- [ ] **Step 4: Run** `uv run pytest -q` — Expected: all pass.
- [ ] **Step 5: Commit** `prioritylink: Hand sticky alerts to z-iris-priority.`

### Task 6: Routing and clearing in the output

**Files:**
- Modify: `src/z_iris/output.py` (`Output` protocol, `RealOutput`, `DryRunOutput`)
- Modify: `tests/test_engine.py` (`Recorder` and other fake outputs gain the new methods as recorders), `tests/test_stream.py` (`Collect` likewise)
- Test: `tests/test_output.py`

**Interfaces:**
- Consumes: `PriorityNotifier.show/clear/clear_server` (Task 5).
- Produces on `Output` (protocol), `RealOutput` and `DryRunOutput`:
  - `clear_read(server: str, ids: set[int] | None) -> None` — `None` means every message on that server.
  - `clear_unless_unread(server: str, unread: set[int]) -> None`.
- `RealOutput.__init__` gains `priority: PriorityNotifier | None = None` (it needs `clear_server`, which `Notifier` lacks). `_show_banner` uses `self.priority` when `notification.action.sticky` and `self.priority` is set, else `self.notifier`. `clear_read` with ids calls `priority.clear(f"z-iris-{server}-{id}")` for each id (whether or not this process showed it); with `None` calls `priority.clear_server(server, set())`. `clear_unless_unread` calls `priority.clear_server(server, unread)`. Both run on the banner worker, so they stay ordered after the show they follow. No priority notifier → both are no-ops. `DryRunOutput` prints `[dry-run] <server>: clear sticky alerts for <n> read messages` / `for all read messages` / `except <n> unread`.

- [ ] **Step 1: Write the failing tests** (fake notifiers record calls):
  - `test_sticky_banners_go_to_the_priority_notifier` — sticky → priority gets the show, normal notifier gets nothing; non-sticky → the reverse.
  - `test_sticky_without_a_priority_notifier_is_an_ordinary_banner`.
  - `test_banner_off_wins_over_sticky` — nothing shown anywhere.
  - `test_a_sticky_batch_summary_is_a_sticky_alert` — `replace(sticky_notification, summary="3 new in #ops")` goes to the priority notifier with that title and the latest message's group.
  - `test_clear_read_clears_by_group_even_if_never_shown` — `clear_read("work", {7, 9})` → clears `z-iris-work-7` and `z-iris-work-9` (after `drain()`).
  - `test_clear_read_all_clears_the_whole_server` — `clear_server("work", set())`.
  - `test_clear_unless_unread_passes_the_unread_ids`.
- [ ] **Step 2: Run** `uv run pytest -q tests/test_output.py` — Expected: FAIL.
- [ ] **Step 3: Implement** in `src/z_iris/output.py`; add the two methods to the test fakes.
- [ ] **Step 4: Run** `uv run pytest -q` — Expected: all pass.
- [ ] **Step 5: Commit** `output: Route sticky banners to z-iris-priority and clear them.`

### Task 7: Read events and reconnect reconcile

**Files:**
- Modify: `src/z_iris/engine.py` (`_forget` → output clears; new `reconcile_unread`)
- Modify: `src/z_iris/stream.py` (`unread_ids`, call after each register)
- Test: `tests/test_engine.py`, `tests/test_stream.py`

**Interfaces:**
- Consumes: `Output.clear_read`, `Output.clear_unless_unread` (Task 6).
- Produces: `Engine.reconcile_unread(server: str, unread: set[int]) -> None`; `stream.unread_ids(registered: dict) -> set[int] | None` — the union of `unread_message_ids` over `unread_msgs["pms"]` (or `"direct_message"`), `"streams"`, `"huddles"`, plus `unread_msgs["mentions"]`; `None` when `unread_msgs` is absent or `unread_msgs.get("old_unreads_missing")` is true.
- `Engine.handle_event`: a read event or deletion still calls `_forget` and also queues `output.clear_read(server, ids)` (ids `None` for `all`), performed outside the lock like other acts. `reconcile_unread` calls `output.clear_unless_unread` and cancels repeats for messages not in `unread`. Paused or stopped engines still clear (clearing never makes noise).
- `ServerStream._session`: after a successful register, `unread = unread_ids(registered)`; if not `None`, `self.engine.reconcile_unread(self.server.name, unread)`.

- [ ] **Step 1: Write the failing tests**
  - `test_engine.py::test_read_events_clear_sticky_alerts` — read `{"type": "update_message_flags", "op": "add", "flag": "read", "messages": [5]}` → `("clear_read", "w", {5})`; with `"all": true` → `("clear_read", "w", None)`; delete event → `("clear_read", "w", {5})`.
  - `test_engine.py::test_reconcile_clears_and_stops_repeats_for_read_messages` — a repeating notification for id 5, then `reconcile_unread("w", {6})` → `("clear_unless_unread", "w", {6})` and no further repeat for 5.
  - `test_engine.py::test_clearing_happens_while_paused`.
  - `test_stream.py::test_unread_ids_from_register` — a reply with pms, streams, huddles and mentions gives the union; missing `unread_msgs` → `None`; `old_unreads_missing: True` → `None`.
  - `test_stream.py::test_each_register_reconciles_unread` — FakeClient returning `BAD_EVENT_QUEUE_ID` once forces a second register; the fake engine sees two `reconcile_unread` calls; a register without `unread_msgs` produces none.
- [ ] **Step 2: Run** `uv run pytest -q tests/test_engine.py tests/test_stream.py` — Expected: FAIL.
- [ ] **Step 3: Implement** in `engine.py` and `stream.py`.
- [ ] **Step 4: Run** `uv run pytest -q` — Expected: all pass.
- [ ] **Step 5: Commit** `engine: Clear sticky alerts on read and after a reconnect.`

### Task 8: Wire it up, document, install, verify with the user

**Files:**
- Modify: `src/z_iris/__main__.py` (`_real_output` passes `priority=PriorityNotifier(fallback=<the normal notifier>)` when `in_bundle()`; at startup warn if `profile_days_left` < 2)
- Modify: `CLAUDE.md` (modules list: `priority`, `prioritylink`; Gotchas: the priority app, its signing mode from Task 1, and that CLAUDE.md's "no batching yet" constraint line is stale — batching exists — so update that line), `README.md` (a "Sticky alerts" section: build, allow, set Alerts, `sticky = true`)
- Test: `tests/test_integration_wiring.py`

**Interfaces:**
- Consumes: everything above. `RealOutput(settings, image_for=..., priority=...)`.

- [ ] **Step 1: Write the failing test** `test_bundle_output_has_a_priority_notifier` — with `in_bundle` patched true, `_real_output(settings).priority` is a `PriorityNotifier` whose fallback is the output's `notifier`; patched false → `priority is None`.
- [ ] **Step 2: Run** it — Expected: FAIL.
- [ ] **Step 3: Implement** the wiring and the docs.
- [ ] **Step 4: Run** `uv run pytest -q` — Expected: all pass.
- [ ] **Step 5: Commit** code and docs separately: `main: Use z-iris-priority for sticky rules.` and `docs: Describe sticky alerts.`
- [ ] **Step 6: Install and verify.** Merge to `main`, push to origin, `scripts/claude/build_app.sh` (with the Task 1 signing env if `profile`), restart z-iris (kill the bundle process, `open ~/Applications/z-iris.app`). Ask the user to add `sticky = true` to their DM rule, then `attention question` and have them check: a DM shows a z-iris priority alert that stays; clicking opens Zulip; reading the DM on another device removes it; a non-sticky message is still an ordinary banner.
