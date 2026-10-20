# Sender-icon spike (2026-10-20)

Plan: `docs/superpowers/plans/2026-10-20-sender-icons.md`, Task 1. Run in
z-iris-priority.app signed with the paid team's profile plus
`com.apple.developer.usernotifications.communication` and
`NSUserActivityTypes = ["INSendMessageIntent"]` in its Info.plist. Checked by
screen capture and by the user.

## Works

Communication notifications from Python with rubicon-objc, no PyObjC Intents:

```python
load_library("UserNotifications"); load_library("Intents")
handle = INPersonHandle.alloc().initWithValue_type_("zulip:work:9", 0)
image = INImage.imageWithURL_(NSURL.fileURLWithPath_(avatar_path))
person = INPerson.alloc().initWithPersonHandle_nameComponents_displayName_image_contactIdentifier_customIdentifier_(
    handle, None, display_name, image, None, "zulip:work:9")
intent = INSendMessageIntent.alloc().initWithRecipients_outgoingMessageType_content_speakableGroupName_conversationIdentifier_serviceName_sender_attachments_(
    recipients_or_None, 1, body, INSpeakableString.alloc().initWithSpokenPhrase_(group) or None,
    conversation_id, "Zulip", person, None)
intent.setImage_forParameterNamed_(group_image, "speakableGroupName")   # groups only
interaction = INInteraction.alloc().initWithIntent_response_(intent, None)
interaction.direction = 2                                                 # incoming
interaction.donateInteractionWithCompletion_(Block(done, None, objc_id))   # error is nil
updated = content.contentByUpdatingWithProvider_error_(intent, None)       # nil on failure
center.addNotificationRequest_withCompletionHandler_(request, Block(...))
```

## What macOS shows

- The supplied image is the big icon, cropped to a circle, with the app's icon
  as a small badge.
- One-to-one (no recipients): the title line is the sender's `displayName`;
  the content's own title is not shown. So `displayName` = today's title
  ("Ada (#ops > deploys)", "Ada") keeps the wording.
- Group (recipients and `speakableGroupName`): first line the sender's
  `displayName`, second line the group name, then the body. "Ada" + "group"
  reads like today's "Ada (group)".
- A group with no image set for `speakableGroupName` shows the plain app icon:
  macOS does not compose a group picture. z-iris must make one.

## Decisions

- Group picture: z-iris draws a 2x2 tile locally: the sender's avatar (when it
  has one) and coloured circles with the initials of up to three other
  members. No extra network fetches (other members' avatars are not in the
  event, and the image rules only allow fetching the sender's).
