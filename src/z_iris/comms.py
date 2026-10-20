"""Communication notifications: the sender's face as the notification's icon.

macOS shows a notification as coming from a person when its content is
updated with an INSendMessageIntent. desktop-notifier cannot do that, so this
builds the notification itself, with rubicon-objc like desktop-notifier, on
the same notification center so its delegate still routes clicks. The
decisions live in send_communication; RubiconBridge only makes the
Objective-C calls proven in docs/sender-icons-spike.md. It needs the
com.apple.developer.usernotifications.communication entitlement; without it
the update fails and callers fall back to a plain notification.
"""

from __future__ import annotations

import asyncio
import ctypes
import functools
import hashlib
import shutil
import tempfile
from concurrent.futures import Future
from pathlib import Path
from typing import Protocol

from z_iris.sender import Sender

LEVELS = {"passive": 0, "active": 1, "time-sensitive": 2}  # UNNotificationInterruptionLevel
DONATE_TIMEOUT = 2.0  # seconds; a donation that never answers is skipped
ADD_TIMEOUT = 5.0  # seconds; an add that never answers is taken as shown (no duplicate)
ENTITLEMENT = "com.apple.developer.usernotifications.communication"
_PALETTE = ("#e5484d", "#f76b15", "#ffc53d", "#30a46c", "#12a594", "#0090ff",
            "#6e56cf", "#d6409f")


class CommsError(Exception):
    """A communication notification could not be made."""


@functools.cache
def has_communication_entitlement() -> bool:
    """Whether this process is signed with the communication entitlement.
    Without it macOS does not refuse: it quietly shows a plain notification
    with no avatar, so callers must check first."""
    try:
        cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        sec = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
        cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        sec.SecTaskCreateFromSelf.restype = ctypes.c_void_p
        sec.SecTaskCreateFromSelf.argtypes = [ctypes.c_void_p]
        sec.SecTaskCopyValueForEntitlement.restype = ctypes.c_void_p
        sec.SecTaskCopyValueForEntitlement.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
        task = sec.SecTaskCreateFromSelf(None)
        if not task:
            return False
        name = cf.CFStringCreateWithCString(None, ENTITLEMENT.encode(), 0x08000100)  # UTF-8
        value = sec.SecTaskCopyValueForEntitlement(task, name, None)
        for ref in (value, name, task):
            if ref:
                cf.CFRelease(ref)
        return bool(value)
    except Exception:
        return False


class Bridge(Protocol):
    def person(self, handle: str, name: str, image: Path | None): ...
    def intent(self, sender, recipients, body: str, group_name: str | None,
               conversation: str, group_image: Path | None): ...
    async def donate(self, intent) -> None: ...
    def content(self, title: str, body: str, thread: str, level: int,
                attachment: Path | None): ...
    def update(self, content, intent): ...
    async def add(self, identifier: str, content) -> str | None: ...


async def send_communication(
    *,
    identifier: str,
    title: str,
    body: str,
    sender: Sender,
    urgency: str = "active",
    group_image: Path | None = None,
    bridge: Bridge | None = None,
) -> None:
    """Show one notification from sender. Raises CommsError on any failure,
    before anything is shown, so the caller can send a plain one instead."""
    bridge = bridge or RubiconBridge()
    try:
        person = bridge.person(sender.handle, sender.name, sender.avatar)
        recipients = None
        if sender.group_name is not None:
            recipients = [bridge.person(handle, name, None)
                          for handle, name in sender.members if handle != sender.handle]
        intent = bridge.intent(person, recipients, body, sender.group_name,
                               sender.conversation, group_image)
        try:
            await asyncio.wait_for(bridge.donate(intent), DONATE_TIMEOUT)
        except asyncio.TimeoutError:
            pass  # the update works without the donation
        # The avatar is the icon now; the thumbnail is only the message's own picture.
        content = bridge.content(title, body, sender.conversation,
                                 LEVELS.get(urgency, 1), sender.picture)
        updated = bridge.update(content, intent)
    except CommsError:
        raise
    except Exception as error:
        raise CommsError(str(error) or type(error).__name__) from error
    if updated is None:
        raise CommsError("macOS refused the sender (is the communication entitlement signed in?)")
    try:
        error = await asyncio.wait_for(bridge.add(identifier, updated), ADD_TIMEOUT)
    except asyncio.TimeoutError:
        return  # probably shown; a fallback could show it twice
    if error:
        raise CommsError(error)


# The group picture: macOS draws nothing for a group without one.


def _initials(name: str) -> str:
    words = [w for w in name.replace("(", " ").split() if w[:1].isalnum()]
    return "".join(w[0].upper() for w in words[:2]) or "?"


def _colour(handle: str) -> str:
    return _PALETTE[int(hashlib.sha1(handle.encode()).hexdigest(), 16) % len(_PALETTE)]


def group_tiles(sender: Sender) -> list[tuple[str, ...]]:
    """Up to four tiles: the sender (avatar, else initials), then others' initials."""
    first = (("avatar", str(sender.avatar)) if sender.avatar
             else ("initials", _initials(sender.name), _colour(sender.handle)))
    others = [("initials", _initials(name), _colour(handle))
              for handle, name in sender.members if handle != sender.handle]
    return [first, *others][:4]


def group_picture(sender: Sender, cache_dir: Path, size: int = 256) -> Path | None:
    """A PNG of the group's tiles, drawn once per set of tiles. None on failure."""
    tiles = group_tiles(sender)
    key = hashlib.sha1(repr(tiles).encode()).hexdigest()[:16]
    path = cache_dir / f"group-{key}.png"
    if path.is_file():
        return path
    try:
        cache_dir.mkdir(parents=True, exist_ok=True)
        _draw(tiles, path, size)
    except Exception:
        return None
    return path if path.is_file() else None


def _draw(tiles: list[tuple[str, ...]], path: Path, size: int) -> None:
    from AppKit import (NSBezierPath, NSBitmapImageRep, NSCalibratedRGBColorSpace,
                        NSColor, NSFont, NSFontAttributeName, NSForegroundColorAttributeName,
                        NSGraphicsContext, NSImage, NSMakeRect, NSPNGFileType, NSString)

    rep = NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
        None, size, size, 8, 4, True, False, NSCalibratedRGBColorSpace, 0, 0)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.setCurrentContext_(NSGraphicsContext.graphicsContextWithBitmapImageRep_(rep))
    half = size / 2
    # one tile fills; two sit side by side; three or four take the quadrants
    if len(tiles) == 1:
        boxes = [(0, 0, size)]
    elif len(tiles) == 2:
        boxes = [(0, half / 2, half), (half, half / 2, half)]
    elif len(tiles) == 3:
        boxes = [(0, half, half), (half, half, half), (half / 2, 0, half)]
    else:
        boxes = [(0, half, half), (half, half, half), (0, 0, half), (half, 0, half)]
    for tile, (x, y, side) in zip(tiles, boxes):
        rect = NSMakeRect(x + 2, y + 2, side - 4, side - 4)
        circle = NSBezierPath.bezierPathWithOvalInRect_(rect)
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        image = NSImage.alloc().initWithContentsOfFile_(tile[1]) if tile[0] == "avatar" else None
        if image is not None:
            image.drawInRect_(rect)
        else:
            text = tile[1] if tile[0] == "initials" else "?"
            colour = tile[2] if tile[0] == "initials" else "#8b8d98"
            r, g, b = (int(colour[i:i + 2], 16) / 255 for i in (1, 3, 5))
            NSColor.colorWithCalibratedRed_green_blue_alpha_(r, g, b, 1).setFill()
            circle.fill()
            attrs = {NSFontAttributeName: NSFont.boldSystemFontOfSize_(side * 0.38),
                     NSForegroundColorAttributeName: NSColor.whiteColor()}
            label = NSString.stringWithString_(text)
            box = label.sizeWithAttributes_(attrs)
            label.drawAtPoint_withAttributes_(
                (x + (side - box.width) / 2, y + (side - box.height) / 2), attrs)
        NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    data = rep.representationUsingType_properties_(NSPNGFileType, {})
    data.writeToFile_atomically_(str(path), True)


class RubiconBridge:
    """The Objective-C calls, as proven in the spike."""

    def __init__(self, center=None) -> None:
        from rubicon.objc import ObjCClass
        from rubicon.objc.runtime import load_library

        load_library("UserNotifications")
        load_library("Intents")
        self.cls = {name: ObjCClass(name) for name in (
            "NSURL", "INPersonHandle", "INPerson", "INImage", "INSendMessageIntent",
            "INSpeakableString", "INInteraction", "UNMutableNotificationContent",
            "UNNotificationRequest", "UNNotificationAttachment", "UNUserNotificationCenter")}
        self.center = center or self.cls["UNUserNotificationCenter"].currentNotificationCenter()

    def _image(self, path: Path | None):
        if path is None:
            return None
        return self.cls["INImage"].imageWithURL_(self.cls["NSURL"].fileURLWithPath_(str(path)))

    def person(self, handle, name, image):
        person_handle = self.cls["INPersonHandle"].alloc().initWithValue_type_(handle, 0)
        return self.cls["INPerson"].alloc().initWithPersonHandle_nameComponents_displayName_image_contactIdentifier_customIdentifier_(
            person_handle, None, name, self._image(image), None, handle)

    def intent(self, sender, recipients, body, group_name, conversation, group_image):
        spoken = (self.cls["INSpeakableString"].alloc().initWithSpokenPhrase_(group_name)
                  if group_name else None)
        intent = self.cls["INSendMessageIntent"].alloc().initWithRecipients_outgoingMessageType_content_speakableGroupName_conversationIdentifier_serviceName_sender_attachments_(
            recipients, 1, body, spoken, conversation, "Zulip", sender, None)
        if group_image is not None:
            intent.setImage_forParameterNamed_(self._image(group_image), "speakableGroupName")
        return intent

    async def donate(self, intent) -> None:
        from rubicon.objc import Block, ObjCInstance, objc_id

        interaction = self.cls["INInteraction"].alloc().initWithIntent_response_(intent, None)
        interaction.direction = 2  # incoming
        future: Future = Future()

        def done(error: objc_id) -> None:
            future.set_result(str(ObjCInstance(error)) if error else None)

        interaction.donateInteractionWithCompletion_(Block(done, None, objc_id))
        await asyncio.wrap_future(future)  # a failed donation still lets the update work

    def content(self, title, body, thread, level, attachment):
        content = self.cls["UNMutableNotificationContent"].alloc().init()
        content.title = title
        content.body = body
        content.threadIdentifier = thread
        content.interruptionLevel = level
        if attachment is not None and Path(attachment).is_file():
            # macOS moves attachments into its own store; give it a copy.
            copy = Path(tempfile.mkdtemp()) / Path(attachment).name
            shutil.copy(attachment, copy)
            item = self.cls["UNNotificationAttachment"].attachmentWithIdentifier_URL_options_error_(
                "", self.cls["NSURL"].fileURLWithPath_(str(copy)), None, None)
            if item is not None:
                content.attachments = [item]
        return content

    def update(self, content, intent):
        return content.contentByUpdatingWithProvider_error_(intent, None)

    async def add(self, identifier, content) -> str | None:
        from rubicon.objc import Block, ObjCInstance, objc_id

        request = self.cls["UNNotificationRequest"].requestWithIdentifier_content_trigger_(
            identifier, content, None)
        future: Future = Future()

        def done(error: objc_id) -> None:
            future.set_result(str(ObjCInstance(error)) if error else None)

        self.center.addNotificationRequest_withCompletionHandler_(request, Block(done, None, objc_id))
        return await asyncio.wrap_future(future)
