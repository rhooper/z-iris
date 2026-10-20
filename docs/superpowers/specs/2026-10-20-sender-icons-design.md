# Sender faces as the notification icon

2026-10-20. Status: design, awaiting approval (builder check done).

## Why

The user wants to see at a glance who a notification is from. macOS can show
the sender's picture as the notification's main icon with the app's icon as a
small badge in the corner, as Messages and Slack do. Apple calls these
communication notifications. Today z-iris attaches the avatar as a thumbnail
on the right, and the left icon is always the z-iris icon.

## Goals

- Every z-iris notification for a message, ordinary banners from z-iris.app
  and sticky alerts from z-iris-priority.app, shows the sender's avatar as the
  main icon with the app's icon as the corner badge. (User: "all".)
- DMs: the sender's face. Group DMs: a group picture. Channel messages: the
  sender's face, with "#channel > topic" in the title as today.
- The thumbnail on the right then shows only an image that is in the message
  itself, never the avatar again. (User confirmed.)
- Everything else about notifications stays as it is: titles, bodies, emoji,
  sticky behaviour, clicks opening Zulip, clearing on read, time-sensitive
  sticky alerts, sounds, flashes.
- Nothing is lost: if a communication notification cannot be made (no
  entitlement, no avatar, an API error), the notification goes out exactly as
  it does today.

## Non-goals

- Batch summaries ("3 new in #ops") have no single sender; they stay as
  today.
- No reply-from-notification, no Siri or Shortcuts integration, no contact
  matching with the macOS address book.
- terminal-notifier fallback banners stay as they are.

## Anti-goals

- A notification that disappears or arrives late because building the intent
  failed or an avatar fetch was slow.
- The sender's avatar shown twice (icon and thumbnail).
- A rebuild that silently drops the entitlement without anyone noticing
  (z-iris should log once when it falls back to plain notifications for
  lack of the entitlement).

## Constraints

- All of the project's constraints (CLAUDE.md): no shell, message text only as
  data, never read zuliprc, sound only through sox.
- Communication notifications need the entitlement
  `com.apple.developer.usernotifications.communication` in each app's
  signature, which needs a development profile from the paid team R9MHS94TL4
  (a Personal Team does not offer it). z-iris-priority.app's profile already
  has it. z-iris.app (`ca.toybox.z-iris`) needs its own: the user adds a
  second target with that bundle id and the Communication Notifications
  capability to `xcode/z-iris-priority/z-iris-priority.xcodeproj` (or a
  sibling project) and builds once.
- Each app's Info.plist needs `NSUserActivityTypes` containing
  `INSendMessageIntent`.
- The main app's profile-signed build must carry the profile's application
  and team identifiers, as the priority app's does (build_app.sh already does
  this for the priority app; generalise it). Two certificates share a name, so
  signing uses a SHA-1.
- desktop-notifier builds its notification content inside one method and
  cannot carry an intent. z-iris needs its own sender for these notifications.
  It should use rubicon-objc like desktop-notifier, so it can share the same
  UNUserNotificationCenter, delegate and click handling, rather than mixing in
  PyObjC's UserNotifications bridge. Adding `pyobjc-framework-Intents` is
  acceptable if rubicon proves impractical for the Intents objects.

## User's answers (from the builder check)

- macOS Focus: not used. Communication notifications may apply to sticky
  alerts too; no Focus testing needed.
- Titles: keep today's wording ("Ada (#ops > deploys)", "Ada (group)",
  "Ada"). If macOS replaces the title with names from the intent, fill the
  intent's fields (for example `INPerson.displayName`, `speakableGroupName`)
  so the shown text reads as today. The spike shows which fields macOS uses.
- Group DMs: a group picture, not the sender's face. Pass the recipients so
  macOS treats it as a group; z-iris may compose a picture from the
  participants' avatars or let macOS build one. Name it so the title reads
  as today ("Ada (group)" style).

## Design author's calls (from the builder check)

- An expired development profile stops a signed app launching, and for
  z-iris.app that means no notifications at all. build_app.sh refuses a
  profile that has expired or expires within 7 days, and z-iris logs a
  warning from 14 days before either app's profile expires (the profiles
  last a year).
- A sender with no fetchable avatar (missing, timed out, or an external
  avatar blocked by `external_images`) gets exactly today's notification
  with the z-iris icon, not a monogram.

## How it works

- Build an `INPerson` for the sender (display name, a stable handle such as
  `zulip:<server>:<user id>`, and an `INImage` from the cached avatar file),
  an `INSendMessageIntent` (sender, recipients for group DMs, a conversation
  identifier, and for channels `speakableGroupName` "#channel > topic"),
  donate it as an incoming `INInteraction`, then make the notification
  content with `content.contentByUpdatingWithProvider(intent)` before adding
  the request.
- The avatar file comes from the existing image resolver and cache
  (`media.ImageResolver`), split so a notification can get the avatar and the
  message image separately. The avatar fetch keeps its existing time budget;
  if it is missing, the notification goes out without a sender icon.
- Clicks, identifiers (`banner_group`), clearing, sticky routing and
  time-sensitive urgency all keep working through the new sender.
- The z-iris -> z-iris-priority `show` request gains the sender fields
  (name, handle, avatar path, conversation id and name, group or not).

## First task: a spike (throwaway)

Before building, prove in z-iris-priority.app (which already has the
entitlement and profile) that a Python-built communication notification shows
the avatar as the icon with the badge: rubicon (or PyObjC Intents) objects,
the donation, and `contentByUpdatingWithProvider`. Report to the user, with
what they should see. If it cannot be made to work, stop and say so.

## What the user does

- Add the `ca.toybox.z-iris` target with Communication Notifications in Xcode
  (paid team) and build once.
- Possibly allow a Focus/communication prompt if macOS shows one.

## Left to the builder

Module layout, the exact sender handle format, how the intent is passed
between processes, tests (fakes for the Objective-C layer; real checks done by
hand with the user), and how the existing `DesktopNotifierBackend` and the
new sender share authorisation and click handling.
