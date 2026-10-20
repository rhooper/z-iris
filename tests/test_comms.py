import asyncio
from pathlib import Path

import pytest

from z_iris.comms import CommsError, group_tiles, send_communication
from z_iris.sender import Sender

AVATAR, PICTURE = Path("/c/av.png"), Path("/c/pic.png")
ADA = Sender("zulip:w:9", "Ada (#ops > deploys)", AVATAR, PICTURE, "w:channel:7:deploys")
GROUP = Sender("zulip:w:9", "Ada", AVATAR, None, "w:dm:3,9,12", "group",
               (("zulip:w:3", "Bob Smith"), ("zulip:w:9", "Ada"), ("zulip:w:12", "Cy")))


class FakeBridge:
    """Records what comms asks the Objective-C side to do."""

    def __init__(self, update_ok=True, add_error=None):
        self.update_ok, self.add_error = update_ok, add_error
        self.calls = []

    def person(self, handle, name, image):
        self.calls.append(("person", handle, name, image))
        return ("person", handle)

    def intent(self, sender, recipients, body, group_name, conversation, group_image):
        self.calls.append(("intent", sender, recipients, body, group_name, conversation, group_image))
        return "intent"

    async def donate(self, intent):
        self.calls.append(("donate", intent))

    def content(self, title, body, thread, level, attachment):
        self.calls.append(("content", title, body, thread, level, attachment))
        return "content"

    def update(self, content, intent):
        self.calls.append(("update", content, intent))
        return "updated" if self.update_ok else None

    async def add(self, identifier, content):
        self.calls.append(("add", identifier, content))
        return self.add_error


def send(bridge, sender=ADA, urgency="active", group_image=None):
    asyncio.run(send_communication(
        identifier="z-iris-w-1", title="t", body="hello", sender=sender, urgency=urgency,
        group_image=group_image, bridge=bridge))


def calls(bridge, kind):
    return [c for c in bridge.calls if c[0] == kind]


def test_a_dm_sends_one_person_with_the_avatar_and_full_title_name():
    bridge = FakeBridge()
    send(bridge)
    assert calls(bridge, "person") == [("person", "zulip:w:9", "Ada (#ops > deploys)", AVATAR)]
    (_, sender, recipients, body, group, conversation, image), = calls(bridge, "intent")
    assert (recipients, body, group, conversation, image) == (None, "hello", None, "w:channel:7:deploys", None)
    assert [c[0] for c in bridge.calls][-3:] == ["content", "update", "add"]
    assert calls(bridge, "add") == [("add", "z-iris-w-1", "updated")]


def test_a_group_sends_its_members_and_group_picture():
    bridge = FakeBridge()
    send(bridge, GROUP, group_image=Path("/c/group.png"))
    people = calls(bridge, "person")
    assert people[0][1:] == ("zulip:w:9", "Ada", AVATAR)
    assert [p[1] for p in people[1:]] == ["zulip:w:3", "zulip:w:12"]  # recipients, not the sender
    (_, _, recipients, _, group, _, image), = calls(bridge, "intent")
    assert len(recipients) == 2 and group == "group" and image == Path("/c/group.png")


def test_the_picture_becomes_the_attachment_never_the_avatar():
    bridge = FakeBridge()
    send(bridge)
    assert calls(bridge, "content")[0][5] == PICTURE
    bridge = FakeBridge()
    send(bridge, GROUP)
    assert calls(bridge, "content")[0][5] is None


@pytest.mark.parametrize("urgency, level", [("passive", 0), ("active", 1), ("time-sensitive", 2)])
def test_urgency_sets_the_interruption_level(urgency, level):
    bridge = FakeBridge()
    send(bridge, urgency=urgency)
    assert calls(bridge, "content")[0][4] == level


def test_an_update_failure_raises_comms_error():
    with pytest.raises(CommsError, match="refused"):
        send(FakeBridge(update_ok=False))


def test_an_add_error_raises_comms_error():
    with pytest.raises(CommsError, match="boom"):
        send(FakeBridge(add_error="boom"))


def test_group_tiles_put_the_sender_first_then_others_initials():
    tiles = group_tiles(GROUP)
    assert tiles[0] == ("avatar", str(AVATAR))
    assert [t[1] for t in tiles[1:]] == ["BS", "C"]
    assert all(t[0] == "initials" and t[2].startswith("#") for t in tiles[1:])
    no_avatar = Sender("zulip:w:9", "Ada", None, None, "c", "group", GROUP.members)
    assert group_tiles(no_avatar)[0][:2] == ("initials", "A")
    many = Sender("zulip:w:1", "A", None, None, "c", "group",
                  tuple((f"zulip:w:{i}", f"P{i}") for i in range(2, 9)))
    assert len(group_tiles(many)) == 4
    blank = Sender("zulip:w:9", "", None, None, "c", "group", (("zulip:w:3", ""),))
    assert [t[1] for t in group_tiles(blank)] == ["?", "?"]


def test_the_group_picture_is_drawn_once_per_group(tmp_path):
    from z_iris.comms import group_picture

    first = group_picture(GROUP, tmp_path)
    assert first is not None and first.suffix == ".png" and first.stat().st_size > 0
    assert group_picture(GROUP, tmp_path) == first
    other = Sender("zulip:w:9", "Ada", None, None, "w:dm:3,9", "group", (("zulip:w:3", "Bob"),))
    assert group_picture(other, tmp_path) != first


class HangingBridge(FakeBridge):
    def __init__(self, hang):
        super().__init__()
        self.hang = hang

    async def donate(self, intent):
        if self.hang == "donate":
            await asyncio.Event().wait()

    async def add(self, identifier, content):
        self.calls.append(("add", identifier, content))
        if self.hang == "add":
            await asyncio.Event().wait()


def test_a_donation_that_never_answers_does_not_stop_the_notification(monkeypatch):
    import z_iris.comms as comms

    monkeypatch.setattr(comms, "DONATE_TIMEOUT", 0.05)
    bridge = HangingBridge("donate")
    asyncio.run(asyncio.wait_for(send_communication(
        identifier="i", title="t", body="b", sender=ADA, bridge=bridge), 1))
    assert calls(bridge, "add")


def test_an_add_that_never_answers_ends_without_error_or_duplicate(monkeypatch):
    import z_iris.comms as comms

    monkeypatch.setattr(comms, "ADD_TIMEOUT", 0.05)
    bridge = HangingBridge("add")
    asyncio.run(asyncio.wait_for(send_communication(
        identifier="i", title="t", body="b", sender=ADA, bridge=bridge), 1))
    assert len(calls(bridge, "add")) == 1


def test_this_test_process_has_no_communication_entitlement():
    from z_iris.comms import has_communication_entitlement

    assert has_communication_entitlement() is False
