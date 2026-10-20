import asyncio

import pytest
from desktop_notifier import Urgency

from z_iris.priority import PriorityService, UrlStore


class FakeNotifier:
    def __init__(self, allowed=True, style="alert", delivered=(), status=None):
        self.allowed = allowed
        self.status = status or ("allowed" if allowed else "denied")
        self.prompted = 0
        self.answer = asyncio.Event  # created lazily inside the running loop
        self.style = style
        self.delivered = list(delivered)
        self.sent = []
        self.cleared = []

    async def request_authorisation(self):
        self.prompted += 1
        return self.allowed

    async def authorisation_status(self):
        return self.status

    async def alert_style(self):
        return self.style

    async def send_notification(self, notification):
        self.sent.append(notification)
        self.delivered.append(notification.identifier)
        return notification.identifier

    async def clear(self, identifier):
        self.cleared.append(identifier)
        if identifier in self.delivered:
            self.delivered.remove(identifier)

    async def get_current_notifications(self):
        return list(self.delivered)


def service(tmp_path, notifier=None, opened=None):
    return PriorityService(
        notifier or FakeNotifier(),
        UrlStore(tmp_path / "urls.json"),
        opener=(opened.append if opened is not None else lambda url: None),
    )


def handle(svc, request):
    return asyncio.run(svc.handle(request))


SHOW = {"op": "show", "title": "Ada", "body": '-x "q"\nline2 🎉',
        "url": "zulip://h/#narrow/dm/9", "group": "z-iris-work-7", "image": None}


def test_status_reports_permission_and_style(tmp_path):
    reply = handle(service(tmp_path, FakeNotifier(style="banner")), {"op": "status"})
    assert reply == {"ok": True, "allowed": True, "style": "banner"}


def test_show_sends_a_time_sensitive_notification_with_the_group_as_identifier(tmp_path):
    notifier = FakeNotifier()
    svc = service(tmp_path, notifier)
    assert handle(svc, SHOW) == {"ok": True}
    sent = notifier.sent[0]
    assert sent.identifier == "z-iris-work-7"
    assert sent.urgency == Urgency.Critical
    assert (sent.title, sent.message) == ("Ada", '-x "q"\nline2 🎉')
    assert sent.sound is None
    assert UrlStore(tmp_path / "urls.json").pop("z-iris-work-7") == "zulip://h/#narrow/dm/9"


def test_show_attaches_an_existing_image(tmp_path):
    image = tmp_path / "a.png"
    image.write_bytes(b"x")
    notifier = FakeNotifier()
    handle(service(tmp_path, notifier), {**SHOW, "image": str(image)})
    assert str(notifier.sent[0].attachment.path) == str(image)
    handle(service(tmp_path, notifier), {**SHOW, "image": str(tmp_path / "gone.png")})
    assert notifier.sent[1].attachment is None


def test_show_when_not_allowed_replies_not_ok(tmp_path):
    notifier = FakeNotifier(allowed=False)  # status "denied"
    assert handle(service(tmp_path, notifier), SHOW) == {"ok": False, "reason": "not allowed"}
    assert notifier.sent == []


def test_clicked_opens_the_stored_url_once(tmp_path):
    opened = []
    svc = service(tmp_path, opened=opened)
    handle(svc, SHOW)
    svc.clicked("z-iris-work-7")
    svc.clicked("z-iris-work-7")
    assert opened == ["zulip://h/#narrow/dm/9"]


def test_a_click_after_a_restart_still_opens_the_url(tmp_path):
    handle(service(tmp_path), SHOW)
    opened = []
    service(tmp_path, opened=opened).clicked("z-iris-work-7")
    assert opened == ["zulip://h/#narrow/dm/9"]


def test_clear_removes_alerts_and_urls(tmp_path):
    notifier = FakeNotifier()
    opened = []
    svc = service(tmp_path, notifier, opened)
    handle(svc, SHOW)
    assert handle(svc, {"op": "clear", "groups": ["z-iris-work-7", "z-iris-work-8"]}) == {"ok": True}
    assert notifier.delivered == []
    svc.clicked("z-iris-work-7")
    assert opened == []


def test_clear_server_keeps_unread_and_other_servers(tmp_path):
    ids = ["z-iris-w-1", "z-iris-w-2", "z-iris-w-2-5", "z-iris-a.b-3", "z-iris-axb-4", "other"]
    notifier = FakeNotifier(delivered=ids)
    svc = service(tmp_path, notifier)
    assert handle(svc, {"op": "clear_server", "server": "w", "keep": [2]}) == {"ok": True}
    assert notifier.cleared == ["z-iris-w-1"]
    handle(svc, {"op": "clear_server", "server": "a.b", "keep": []})
    assert notifier.cleared == ["z-iris-w-1", "z-iris-a.b-3"]


@pytest.mark.parametrize("request_", [
    {}, {"op": "show"}, {"op": "nope"}, {"op": "clear", "groups": "z-iris-w-1"},
    {"op": "clear_server", "server": "w", "keep": ["x"]}, [], "show",
])
def test_malformed_requests_reply_not_ok(tmp_path, request_):
    reply = handle(service(tmp_path), request_)
    assert reply["ok"] is False and reply["reason"]


def test_url_store_survives_restart_and_corruption(tmp_path):
    path = tmp_path / "urls.json"
    UrlStore(path).put("g", "zulip://x")
    assert UrlStore(path).pop("g") == "zulip://x"
    path.write_text("{")
    assert UrlStore(path).pop("g") is None
    store = UrlStore(tmp_path / "missing" / "urls.json")
    store.put("h", "zulip://y")
    store.drop(["h"])
    assert store.pop("h") is None


def test_serve_answers_each_line_in_order(tmp_path):
    from z_iris.priority import serve

    written = []
    serve(['{"op":"status"}\n', "garbage\n", "\n"], service(tmp_path), written.append, asyncio.run)
    replies = [__import__("json").loads(line) for line in written]
    assert all(line.endswith("\n") and line.count("\n") == 1 for line in written)
    assert replies == [
        {"ok": True, "allowed": True, "style": "alert"},
        {"ok": False, "reason": "bad json"},
    ]


def test_clear_touches_only_alerts_on_screen(tmp_path):
    notifier = FakeNotifier(delivered=["z-iris-w-3"])
    groups = [f"z-iris-w-{i}" for i in range(1, 5001)]
    assert handle(service(tmp_path, notifier), {"op": "clear", "groups": groups}) == {"ok": True}
    assert notifier.cleared == ["z-iris-w-3"]



class PromptingNotifier(FakeNotifier):
    """Permission not decided yet: the prompt never answers during the test."""

    def __init__(self):
        super().__init__(status="undetermined")

    async def request_authorisation(self):
        self.prompted += 1
        await asyncio.Event().wait()


def bounded(svc, request):
    return asyncio.run(asyncio.wait_for(svc.handle(request), 1))


def test_status_never_waits_for_the_permission_prompt(tmp_path):
    notifier = PromptingNotifier()
    reply = bounded(service(tmp_path, notifier), {"op": "status"})
    assert reply == {"ok": True, "allowed": False, "style": "alert"}
    assert notifier.prompted == 0


def test_an_undecided_permission_prompts_in_the_background_on_show(tmp_path):
    notifier = PromptingNotifier()
    svc = service(tmp_path, notifier)

    async def two_shows():
        first = await asyncio.wait_for(svc.handle(SHOW), 1)
        second = await asyncio.wait_for(svc.handle(SHOW), 1)
        await asyncio.sleep(0)
        return first, second

    first, second = asyncio.run(two_shows())
    assert first == second == {"ok": False, "reason": "waiting for permission"}
    assert notifier.prompted == 1 and notifier.sent == []


def test_clears_never_prompt(tmp_path):
    notifier = PromptingNotifier()
    svc = service(tmp_path, notifier)
    bounded(svc, {"op": "clear", "groups": ["z-iris-w-1"]})
    bounded(svc, {"op": "clear_server", "server": "w", "keep": []})
    assert notifier.prompted == 0
