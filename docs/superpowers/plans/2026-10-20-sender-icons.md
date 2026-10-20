# Sender Icons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every message notification from z-iris and z-iris priority shows the sender's avatar (a group picture for group DMs) as its main icon with the app badge, keeping today's title wording.

**Architecture:** A pure `Sender` description of who a notification is from is built from each message and its two images (avatar, in-message picture). It travels with the notification to whichever backend shows it: z-iris's `DesktopNotifierBackend`, or z-iris-priority through the JSON `show` request. A new `comms` module, using rubicon-objc like desktop-notifier, builds the UNNotificationContent itself, attaches an `INSendMessageIntent`, donates it, and adds the request to the same notification center, so desktop-notifier's delegate still routes clicks (through the app-wide `on_clicked(identifier)`). If anything fails, the notification goes out exactly as today.

**Tech Stack:** Python 3.13, rubicon-objc 0.5 (UserNotifications, Intents), desktop-notifier 6.2, pytest; clang/codesign; Xcode (user, once).

**Spec:** `docs/superpowers/specs/2026-10-20-sender-icons-design.md`

## Global Constraints

- Never use a shell to run a command; message text only as argv or JSON data. Never read zuliprc contents. Sound only through sox.
- A bundle's executable is its own `CFBundleExecutable`, signed `-i <bundle id>`, never `--deep`.
- Entitlement `com.apple.developer.usernotifications.communication`; both apps' Info.plist gain `NSUserActivityTypes` = `["INSendMessageIntent"]`.
- Profiles come from the paid team R9MHS94TL4; sign by SHA-1 (two identities share a name). The profile's `com.apple.application-identifier` and `com.apple.developer.team-identifier` go into the signed entitlements.
- build_app.sh refuses a profile that has expired or expires within 7 days. z-iris logs a warning from 14 days before either app's profile expires.
- Titles keep today's wording: `Sender (#channel > topic)`, `Sender (group)`, `Sender`. Batch summaries stay plain.
- No avatar, or no entitlement, or any comms error: exactly today's notification (z-iris icon, avatar or picture as thumbnail). Comms failure for lack of entitlement is logged once.
- With a face icon, the thumbnail is only an image from the message, never the avatar.
- Tests: `uv run pytest -q` all pass; test-first; never pipe pytest's result through another command when checking it.

## Review Focus

- A message whose avatar fetch times out or is blocked by `external_images`: it must arrive as today's plain notification, not late and not without a banner. Test in Task 5.
- The comms path raising inside rubicon (unknown selector, nil image, entitlement missing): falls back to the plain path in the same call, once-only log. Test in Task 5.
- A click on a communication notification after z-iris restarted (no in-memory url): the main app must still open Zulip — persist urls like the priority app. Test in Task 5.
- Group DM where some member names are missing from the event: no crash, the group still shows. Test in Task 3.
- Sender names or topics with quotes, newlines or emoji in the JSON `show` request: arrive intact. Test in Task 6.

---

### Task 1: Spike — a communication notification from Python (throwaway)

**Files:** scratchpad only; then `docs/sender-icons-spike.md` (results).

- [ ] **Step 1:** Copy `~/Applications/z-iris-priority.app` (profile-signed, has the entitlement) to a scratch copy *in `~/Applications`* (prompts only work from a real location; name it `z-iris-priority.app` again only after restoring — use the installed one directly and restore by re-running build_app.sh afterwards). Add `NSUserActivityTypes` = `["INSendMessageIntent"]` to its Info.plist with `plutil -insert`, re-sign exactly as build_app.sh does with the profile (same identity SHA-1 `E92D95918678084B96F0021C2AC8218D690782FB`, entitlements from `scripts/claude/priority.entitlements` plus `com.apple.developer.usernotifications.communication` and the profile's two identifiers).
- [ ] **Step 2:** A one-off module in the scratchpad (run with the launcher's `-m` passthrough from that directory) that, with rubicon-objc: loads `UserNotifications` and `Intents`; builds an `INPerson` (handle `INPersonHandle` value `zulip:work:9` type unknown, `nameComponents` nil, `displayName` "Ada (#ops > deploys)", `image` `INImage.imageWithURL(file URL of a cached avatar in ~/Library/Caches/z-iris/media)`, `contactIdentifier` nil, `customIdentifier` "zulip:work:9"); an `INSendMessageIntent` (recipients nil, outgoingMessageType text, content "hi", speakableGroupName nil, conversationIdentifier "work:dm:9", serviceName "Zulip", sender that person); donates `INInteraction(intent, response nil)` with direction incoming; builds `UNMutableNotificationContent` (title, body), calls `contentByUpdatingWithProvider:error:`, adds the request (identifier `z-iris-spike-1`). A second notification for a group: two recipients, `speakableGroupName` "Ada (group)".
- [ ] **Step 3:** The user looks (say what to look for; `attention question`): face as the main icon with the badge? Title text as given (full "Ada (#ops > deploys)")? Group: a group picture and "Ada (group)"? Record which fields macOS shows as the title.
- [ ] **Step 4:** Write `docs/sender-icons-spike.md` with the results and the exact rubicon calls that worked (selector names, argument order). If no face appears, stop and report to the user. If rubicon cannot build an object, try `pyobjc-framework-Intents` in the same spike and record it.
- [ ] **Step 5:** Restore the installed priority app by re-running build_app.sh with the profile (see README, Sticky alerts). Commit `docs/sender-icons-spike.md`: `docs: Record the sender-icon spike.`

### Task 2: Two images per message, and group member names

**Files:**
- Modify: `src/z_iris/media.py` (`MessageImages`, `ImageResolver.images_for`; `image_for` delegates)
- Modify: `src/z_iris/message.py` (`dm_names`)
- Test: `tests/test_media.py`, `tests/test_message.py`

**Interfaces:**
- Produces: `@dataclass(frozen=True) class MessageImages: avatar: Path | None; picture: Path | None` and `ImageResolver.images_for(message) -> MessageImages` (picture = first in-message image; avatar = sender avatar; one shared deadline as today; never raises). `image_for(message)` keeps returning `picture or avatar`. `Message.dm_names: tuple[str, ...] = ()` — the other participants' full names in `dm_user_ids` order (empty for channels).

- [ ] **Step 1: Failing tests:** `test_images_for_returns_avatar_and_picture_separately` (message with an image and an avatar url, fake http/convert as the existing media tests do: both paths set); `test_images_for_without_picture_has_only_avatar`; `test_image_for_still_prefers_the_picture`; `test_message_carries_group_member_names` (display_recipient `[{"id":9,"full_name":"Ada"},{"id":12,"full_name":"Cy"},{"id":5,"full_name":"Me"}]`, self 5 → `dm_names == ("Ada", "Cy")`; a member without `full_name` gives `""`).
- [ ] **Step 2: Run** `uv run pytest -q tests/test_media.py tests/test_message.py` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `uv run pytest -q` — all pass.
- [ ] **Step 5: Commit** `media: Resolve the avatar and the message picture separately.`

### Task 3: `Sender` — who a notification is from

**Files:**
- Create: `src/z_iris/sender.py`
- Test: `tests/test_sender.py`

**Interfaces:**
- Consumes: `MessageImages`, `Message.dm_names` (Task 2); `output.banner_title` wording.
- Produces: `@dataclass(frozen=True) class Sender: handle: str; name: str; avatar: Path | None; picture: Path | None; conversation: str; group_name: str | None; members: tuple[tuple[str, str], ...]` with `to_json() -> dict` and `Sender.from_json(data: object) -> Sender | None` (None on anything malformed; paths become `Path`). `sender_for(message: Message, title: str, images: MessageImages) -> Sender | None` — None when `images.avatar` is None and it is not a group DM.
  - handle `zulip:<server>:<sender_id>`; `name` = `title` for DMs and channels (so the title shows today's wording); conversation `"<server>:dm:<ids comma-joined>"` or `"<server>:channel:<channel_id>:<topic>"`.
  - Group DM (`len(dm_user_ids) > 1`): `group_name = title` ("Ada (group)"), `members` = `(handle, name)` for each of `dm_user_ids`/`dm_names` (blank names allowed), avatar may be None.
  - The spike's findings (Task 1) override where `name`/`group_name` go if macOS shows a different field; record a ruling.
- [ ] **Step 1: Failing tests:** DM, channel, group, group with a blank member name, no avatar (DM → None), JSON round trip with `'Ada "x"\n🎉'`, `from_json` of `{}`, `[]`, `{"handle": 1}` → None.
- [ ] **Step 2: Run** `uv run pytest -q tests/test_sender.py` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `uv run pytest -q` — all pass.
- [ ] **Step 5: Commit** `sender: Describe who a notification is from.`

### Task 4: `comms` — communication notifications through rubicon

**Files:**
- Create: `src/z_iris/comms.py`
- Test: `tests/test_comms.py`

**Interfaces:**
- Consumes: `Sender` (Task 3); the working calls from `docs/sender-icons-spike.md`.
- Produces: `class CommsError(Exception)`; `async send_communication(center, *, identifier: str, title: str, body: str, sender: Sender, urgency: str = "active", sound: bool = False, objc=None) -> None` — builds the person(s), the intent, donates, builds `UNMutableNotificationContent` (title, body, `threadIdentifier` = `sender.conversation`, interruption level from `urgency` in `"passive"|"active"|"time-sensitive"`, attachment from `sender.picture` copied to a temp file as desktop-notifier does), updates it with the intent, and adds the request; raises `CommsError` with the reason on any failure (including the update returning an error, which is what a missing entitlement looks like). `objc` is an injectable namespace (`ObjCClass`, `Block`, `load_library`, `NSURL`...) so tests can use fakes; default is rubicon's.
- [ ] **Step 1: Failing tests** with a fake objc namespace recording calls: `test_a_dm_sends_one_person_with_the_avatar_and_full_title_name`; `test_a_group_sends_members_and_the_group_name`; `test_the_picture_becomes_the_attachment_never_the_avatar`; `test_an_update_error_raises_comms_error`; `test_time_sensitive_sets_the_interruption_level`.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `uv run pytest -q` — all pass.
- [ ] **Step 5: Commit** `comms: Send communication notifications with the sender's face.`

### Task 5: z-iris's banners use it

**Files:**
- Modify: `src/z_iris/notify.py` (`Notifier.show` gains `sender: Sender | None = None`; `DesktopNotifierBackend` tries comms first; `TerminalNotifier` ignores it; app-wide click handler with a persisted url map)
- Modify: `src/z_iris/output.py` (`RealOutput` gets `images_for` instead of `image_for`; builds the `Sender`; title-only banners also get it; batch summaries never)
- Modify: `src/z_iris/__main__.py` (`ImageResolver.images_for`)
- Test: `tests/test_notify.py`, `tests/test_output.py`, `tests/test_integration_wiring.py`

**Interfaces:**
- Consumes: `send_communication`, `CommsError` (Task 4); `sender_for` (Task 3); `MessageImages` (Task 2); `priority.UrlStore` (reuse with its own file `~/Library/Application Support/z-iris/banner-urls.json`).
- Produces: `DesktopNotifierBackend.__init__(..., comms=send_communication, urls: UrlStore | None = None)`. `show(title, body, url, image=None, group=None, silent=True, sender=None)`: with a sender and native permission, `await comms(center, ...)` using the DesktopNotifier's backend center; on `CommsError`, warn once (`"sender icons unavailable (<reason>); plain banners"`) and send exactly today's notification with `image`. The app-wide `on_clicked(identifier)` opens the url stored under the group (stored for every banner, comms or not; popped on click; dropped on `clear`).
- [ ] **Step 1: Failing tests:** sender path calls comms and not `send_notification`; `CommsError` falls back to `send_notification` with `image` and warns once across two shows; no sender → today's path unchanged; a click by identifier after a new backend instance (same store path) opens the url; `RealOutput` passes `sender` with `picture` as the plain fallback `image` unchanged from today (`picture or avatar`); an avatar-less DM passes `sender=None`; a summary passes `sender=None`.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `uv run pytest -q` — all pass.
- [ ] **Step 5: Commit** `notify: Show the sender's face on z-iris banners.`

### Task 6: Sticky alerts use it

**Files:**
- Modify: `src/z_iris/prioritylink.py` (`show(..., sender=None)` adds `"sender": sender.to_json()` to the request)
- Modify: `src/z_iris/priority.py` (`_show` uses `send_communication` when `Sender.from_json(request.get("sender"))` is not None, urgency `"time-sensitive"`; on `CommsError`, today's path; warn-once is reported back as `{"ok": true, "plain": "<reason>"}` so z-iris logs it once)
- Test: `tests/test_prioritylink.py`, `tests/test_priority.py`

**Interfaces:**
- Consumes: `Sender.to_json/from_json` (Task 3), `send_communication` (Task 4).
- [ ] **Step 1: Failing tests:** request carries the sender JSON intact (quotes, newline, emoji); service with a sender calls comms with urgency time-sensitive and stores the url; comms failure falls back to `send_notification` and replies `plain`; a malformed `sender` is ignored (plain alert, ok); z-iris warns once for repeated `plain` replies.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `uv run pytest -q` — all pass.
- [ ] **Step 5: Commit** `priority: Show the sender's face on sticky alerts.`

### Task 7: Build, sign and warn

**Files:**
- Modify: `scripts/claude/build_app.sh` (both Info.plists get `NSUserActivityTypes`; `Z_IRIS_PROFILE` signs z-iris.app like the priority app with new `scripts/claude/z-iris.entitlements`; `priority.entitlements` gains communication; refuse a profile with under 7 days left; factor the profile signing into one function)
- Create: `scripts/claude/z-iris.entitlements`
- Modify: `src/z_iris/__main__.py` (warn from 14 days, for both apps' profiles; the main app's own bundle path from `NSBundle.mainBundle().bundlePath()`)
- Modify: `README.md`, `CLAUDE.md`, `xcode/` note
- Test: `tests/test_build_app.py`, `tests/test_integration_wiring.py`

- [ ] **Step 1: Failing tests:** both built Info.plists have `NSUserActivityTypes == ["INSendMessageIntent"]`; `Z_IRIS_PROFILE` pointing to a missing file fails the build with "no provisioning profile"; the startup warning fires at 10 days left (and names which app) and not at 30.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement.** The 7-day refusal reads `ExpirationDate` with `security cms -D` and PlistBuddy, compares with `date -u +%s`; verified by hand (no test profile exists).
- [ ] **Step 4: Run** `uv run pytest -q` — all pass.
- [ ] **Step 5: Commit** code and docs separately: `build_app: Sign z-iris with a profile for sender icons.`, `docs: Describe sender icons.`

### Task 8: Profile for z-iris, install, verify with the user

- [ ] **Step 1:** Give the user exact Xcode steps: in `xcode/z-iris-priority/z-iris-priority.xcodeproj`, File → New → Target… → macOS → App, product name `z-iris`, Team = paid "Rose Hooper" (not Personal Team), Bundle Identifier exactly `ca.toybox.z-iris`, + Capability → Communication Notifications, select the new scheme, ⌘B. `attention question`. Commit the project changes (not `xcuserdata`).
- [ ] **Step 2:** Find the new profile (`~/Library/Developer/Xcode/UserData/Provisioning Profiles/`, application identifier `R9MHS94TL4.ca.toybox.z-iris`); test-build to the scratchpad and launch `--help` to prove it is not killed.
- [ ] **Step 3:** Final whole-branch review, fix pass, merge to main, push (user asked for merge + push in the last round; confirm again if anything differs). Stop z-iris and z-iris priority, build both into `~/Applications` with both profiles, restart z-iris.
- [ ] **Step 4:** With the user (`attention question`): a DM shows Ada's face with the z-iris badge and title "Ada"; a channel message shows the face and "Ada (#ops > deploys)"; a group DM shows a group picture and "Ada (group)"; a sticky DM shows the face with the z-iris priority badge; clicking each opens Zulip; a message with an image shows it as the thumbnail.
