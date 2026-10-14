import os
import threading
from pathlib import Path

import pytest

from z_iris import media
from z_iris.media import ClientRegistry, HttpError, ImageResolver, extract_image_urls
from z_iris.message import Message

PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 20


def msg(content="hi", avatar_url=None, server="main", host="chat.example.com"):
    return Message(
        server=server, host=host, id=1, kind="dm", sender_id=2, sender_name="A",
        content=content, flags=frozenset(), channel_id=None, channel_name=None,
        topic=None, dm_user_ids=(2,), avatar_url=avatar_url,
    )


class FakeClient:
    base_url = "https://chat.example.com/"
    email = "bot@example.com"
    api_key = "SECRETKEY"


class Net:
    """Records calls to http_get; responds from a url -> result map."""

    def __init__(self, routes=None):
        self.routes = routes or {}
        self.calls = []

    def __call__(self, url, *, auth=None, timeout, max_bytes, **kw):
        self.calls.append((url, auth, timeout, max_bytes))
        self.kw = kw
        result = self.routes.get(url)
        if result is None:
            raise HttpError("404")
        if isinstance(result, Exception):
            raise result
        return result


def fake_convert(src, dst, max_px):
    Path(dst).write_bytes(Path(src).read_bytes())
    return True


def resolver(tmp_path, net, client=FakeClient(), **kw):
    reg = ClientRegistry()
    if client is not None:
        reg.set("main", client)
    kw.setdefault("convert", fake_convert)
    kw.setdefault("external_images", True)
    return ImageResolver(reg, tmp_path / "cache", http_get=net, **kw)


# extraction


@pytest.mark.parametrize(
    "content,expected",
    [
        ("![pic](https://x.com/a.png)", ["https://x.com/a.png"]),
        ("![pic](https://x.com/a)", ["https://x.com/a"]),
        ("![pic](https://x.com/a.png \"title\")", ["https://x.com/a.png"]),
        ("see https://x.com/a.JPG now", ["https://x.com/a.JPG"]),
        ("see https://x.com/a.webp?x=1 now", ["https://x.com/a.webp?x=1"]),
        ("https://x.com/page.html", []),
        ("[name](/user_uploads/1/ab/cat.jpeg)", ["/user_uploads/1/ab/cat.jpeg"]),
        ("[doc](/user_uploads/1/ab/file.pdf)", []),
        ("[site](https://x.com/page)", []),
        ("![t](/thumbnail?url=user_uploads%2F1%2Fa.png&size=full)",
         ["/thumbnail?url=user_uploads%2F1%2Fa.png&size=full"]),
        ("[![alt](https://x.com/i.gif)](https://x.com/page)", ["https://x.com/i.gif"]),
        ("first https://a.com/1.png then ![x](https://b.com/2.png)",
         ["https://a.com/1.png", "https://b.com/2.png"]),
        ("![a](ftp://x.com/a.png)", []),
        ("![a](javascript:alert(1))", []),
        ("```\nhttps://x.com/code.png\n```", []),
        ("![a](https://x.com/a.png) ![a](https://x.com/a.png)", ["https://x.com/a.png"]),
        ("(https://x.com/a.png)", ["https://x.com/a.png"]),
        ("", []),
    ],
)
def test_extract(content, expected):
    assert extract_image_urls(content) == expected


# registry


def test_registry_thread_safe_and_get():
    reg = ClientRegistry()
    assert reg.get("a") is None

    def work(i):
        for _ in range(200):
            reg.set(f"s{i}", i)
            reg.get(f"s{i}")

    threads = [threading.Thread(target=work, args=(i,)) for i in range(8)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert reg.get("s3") == 3


# resolver


def test_external_image_no_credentials(tmp_path):
    net = Net({"https://x.com/a.png": ("image/png", PNG)})
    path = resolver(tmp_path, net).image_for(msg("![p](https://x.com/a.png)"))
    assert path.read_bytes() == PNG
    assert net.calls[0][1] is None


def test_credentials_never_to_foreign_host(tmp_path):
    net = Net({
        "https://evil.example.org/chat.example.com/a.png": ("image/png", PNG),
        "https://chat.example.com.evil.org/a.png": ("image/png", PNG),
    })
    r = resolver(tmp_path, net)
    r.image_for(msg("![p](https://evil.example.org/chat.example.com/a.png)"))
    r.image_for(msg("![p](https://chat.example.com.evil.org/a.png)"))
    assert net.calls and all(c[1] is None for c in net.calls)


def test_relative_upload_uses_auth_on_server(tmp_path):
    url = "https://chat.example.com/user_uploads/1/ab/cat.png"
    net = Net({url: ("image/png", PNG)})
    path = resolver(tmp_path, net).image_for(msg("[c](/user_uploads/1/ab/cat.png)"))
    assert path is not None
    assert net.calls[0][0] == url
    assert net.calls[0][1] == ("bot@example.com", "SECRETKEY")


def test_absolute_same_host_uses_auth(tmp_path):
    url = "https://chat.example.com/user_uploads/1/ab/cat.png"
    net = Net({url: ("image/png", PNG)})
    resolver(tmp_path, net).image_for(msg(f"![c]({url})"))
    assert net.calls[0][1] == ("bot@example.com", "SECRETKEY")


def test_thumbnail_relative(tmp_path):
    url = "https://chat.example.com/thumbnail?url=user_uploads%2F1%2Fa.png&size=full"
    net = Net({url: ("image/png", PNG)})
    path = resolver(tmp_path, net).image_for(
        msg("![t](/thumbnail?url=user_uploads%2F1%2Fa.png&size=full)")
    )
    assert path is not None and net.calls[0][1] is not None


def test_temporary_url_preferred(tmp_path):
    class Client(FakeClient):
        def get_file_temporary_url(self, path):
            assert path == "1/ab/cat.png"
            return {"result": "success", "url": "/user_uploads/1/ab/cat.png?token=T"}

    tmp = "https://chat.example.com/user_uploads/1/ab/cat.png?token=T"
    net = Net({tmp: ("image/png", PNG)})
    path = resolver(tmp_path, net, client=Client()).image_for(
        msg("[c](/user_uploads/1/ab/cat.png)")
    )
    assert path is not None
    assert net.calls[0][0] == tmp and net.calls[0][1] is None


def test_temporary_url_failure_falls_back_to_auth(tmp_path):
    class Client(FakeClient):
        def get_file_temporary_url(self, path):
            raise RuntimeError("nope")

    url = "https://chat.example.com/user_uploads/1/ab/cat.png"
    net = Net({url: ("image/png", PNG)})
    assert resolver(tmp_path, net, client=Client()).image_for(
        msg("[c](/user_uploads/1/ab/cat.png)")
    )
    assert net.calls[0][1] is not None


def test_relative_without_client_is_skipped(tmp_path):
    net = Net()
    assert resolver(tmp_path, net, client=None).image_for(
        msg("[c](/user_uploads/1/ab/cat.png)")
    ) is None
    assert net.calls == []


def test_avatar_fallback_absolute(tmp_path):
    net = Net({"https://cdn.x.com/av.png": ("image/png", PNG)})
    path = resolver(tmp_path, net).image_for(msg("no image", "https://cdn.x.com/av.png"))
    assert path is not None
    assert net.calls[0][1] is None


def test_avatar_relative(tmp_path):
    net = Net({"https://chat.example.com/user_avatars/1.png": ("image/png", PNG)})
    assert resolver(tmp_path, net).image_for(msg("x", "/user_avatars/1.png"))


def test_no_image_no_avatar(tmp_path):
    assert resolver(tmp_path, Net()).image_for(msg("x", None)) is None


def test_failed_image_falls_back_to_avatar(tmp_path):
    net = Net({"https://cdn.x.com/av.png": ("image/png", PNG)})
    path = resolver(tmp_path, net).image_for(
        msg("![p](https://x.com/missing.png)", "https://cdn.x.com/av.png")
    )
    assert path is not None


def test_failure_returns_none_never_raises(tmp_path):
    net = Net({"https://x.com/a.png": RuntimeError("boom")})
    assert resolver(tmp_path, net).image_for(msg("![p](https://x.com/a.png)")) is None


def test_non_image_content_type_rejected(tmp_path):
    net = Net({"https://x.com/a.png": ("text/html", b"<html>")})
    assert resolver(tmp_path, net).image_for(msg("![p](https://x.com/a.png)")) is None


def test_svg_skipped(tmp_path):
    net = Net({"https://x.com/a.svg": ("image/svg+xml", b"<svg/>")})
    assert resolver(tmp_path, net).image_for(msg("![p](https://x.com/a.svg)")) is None


def test_webp_converted(tmp_path):
    seen = []

    def convert(src, dst, max_px):
        seen.append(max_px)
        Path(dst).write_bytes(PNG)
        return True

    net = Net({"https://x.com/a.webp": ("image/webp", b"RIFFxxxxWEBP")})
    path = resolver(tmp_path, net, convert=convert).image_for(
        msg("![p](https://x.com/a.webp)")
    )
    assert path.read_bytes() == PNG and seen


def test_convert_failure_returns_none(tmp_path):
    net = Net({"https://x.com/a.png": ("image/png", PNG)})
    r = resolver(tmp_path, net, convert=lambda s, d, m: False)
    assert r.image_for(msg("![p](https://x.com/a.png)")) is None


def test_size_cap_passed_and_error_handled(tmp_path):
    net = Net({"https://x.com/a.png": HttpError("too large")})
    r = resolver(tmp_path, net, max_image_bytes=1234)
    assert r.image_for(msg("![p](https://x.com/a.png)")) is None
    assert net.calls[0][3] == 1234


def test_timeout_passed(tmp_path):
    net = Net({"https://x.com/a.png": ("image/png", PNG)})
    resolver(tmp_path, net, timeout=2.5).image_for(msg("![p](https://x.com/a.png)"))
    assert net.calls[0][2] == 2.5


def test_cache_hit_no_second_fetch(tmp_path):
    net = Net({"https://x.com/a.png": ("image/png", PNG)})
    r = resolver(tmp_path, net)
    a = r.image_for(msg("![p](https://x.com/a.png)"))
    b = r.image_for(msg("![p](https://x.com/a.png)"))
    assert a == b and len(net.calls) == 1


def test_cache_keyed_per_server(tmp_path):
    net = Net({"https://chat.example.com/user_uploads/a.png": ("image/png", PNG)})
    r = resolver(tmp_path, net)
    r.image_for(msg("[c](/user_uploads/a.png)", server="main"))
    assert r.image_for(msg("[c](/user_uploads/a.png)", server="other")) is None


def test_cache_pruned_to_cap(tmp_path):
    net = Net({f"https://x.com/{i}.png": ("image/png", PNG) for i in range(5)})
    r = resolver(tmp_path, net, cache_cap_bytes=len(PNG) * 2)
    for i in range(5):
        p = r.image_for(msg(f"![p](https://x.com/{i}.png)"))
        os.utime(p, (1000 + i, 1000 + i))
    files = list((tmp_path / "cache").glob("*.png"))
    assert len(files) <= 2
    assert sum(f.stat().st_size for f in files) <= len(PNG) * 2


def test_default_cache_dir(monkeypatch, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    assert media.default_cache_dir() == tmp_path / "Library/Caches/z-iris/media"


# default http_get


class Resp:
    def __init__(self, status=200, headers=None, chunks=(b"abc",)):
        self.status_code = status
        self.headers = headers or {"content-type": "image/png"}
        self._chunks = chunks

    def iter_content(self, n):
        yield from self._chunks

    def close(self):
        pass


def test_http_get_scheme_rejected():
    with pytest.raises(HttpError):
        media.http_get("file:///etc/passwd", timeout=1, max_bytes=10, _get=lambda *a, **k: Resp())


def test_http_get_size_cap():
    get = lambda *a, **k: Resp(chunks=(b"x" * 6, b"x" * 6))  # noqa: E731
    with pytest.raises(HttpError):
        media.http_get("https://x.com/a", timeout=1, max_bytes=10, _get=get)


def test_http_get_declared_length_cap():
    get = lambda *a, **k: Resp(headers={"content-type": "image/png", "content-length": "999"})  # noqa: E731
    with pytest.raises(HttpError):
        media.http_get("https://x.com/a", timeout=1, max_bytes=10, _get=get)


def test_http_get_redirect_drops_auth_on_foreign_host():
    calls = []

    def get(url, **kw):
        calls.append((url, kw.get("auth"), kw.get("allow_redirects")))
        if url.startswith("https://chat.example.com"):
            return Resp(302, {"location": "https://cdn.other.com/x.png"})
        return Resp()

    ctype, body = media.http_get(
        "https://chat.example.com/user_uploads/1/a/x.png", auth=("e", "k"),
        auth_base="https://chat.example.com/", timeout=1, max_bytes=100, _get=get,
    )
    assert body == b"abc"
    assert calls[0][1] == ("e", "k")
    assert calls[1][1] is None
    assert all(c[2] is False for c in calls)


def test_http_get_redirect_to_bad_scheme_and_loops():
    get = lambda url, **k: Resp(302, {"location": "ftp://x/a"})  # noqa: E731
    with pytest.raises(HttpError):
        media.http_get("https://x.com/a", timeout=1, max_bytes=10, _get=get)
    get = lambda url, **k: Resp(302, {"location": "https://x.com/a"})  # noqa: E731
    with pytest.raises(HttpError):
        media.http_get("https://x.com/a", timeout=1, max_bytes=10, _get=get)


def test_http_get_error_status():
    with pytest.raises(HttpError):
        media.http_get("https://x.com/a", timeout=1, max_bytes=10, _get=lambda *a, **k: Resp(404))


def test_sips_argv_only(monkeypatch, tmp_path):
    calls = []

    class Done:
        returncode = 0

    def run(argv, **kw):
        calls.append((argv, kw))
        Path(argv[-1]).write_bytes(PNG)
        return Done()

    monkeypatch.setattr(media.subprocess, "run", run)
    src = tmp_path / "a; rm -rf x"
    src.write_bytes(b"x")
    assert media.sips_convert(src, tmp_path / "out.png", 256)
    argv, kw = calls[0]
    assert isinstance(argv, list) and argv[0] == "sips" and "256" in argv
    assert not kw.get("shell") and kw.get("timeout")


def test_stream_registers_its_client():
    from tests.test_stream import Collect, FakeClient as StreamClient, dm_event, make_stream

    client = StreamClient([{"result": "success", "events": [dm_event(0)]}])
    out = Collect(want=1)
    stream = make_stream(client, out)
    stream.start()
    assert out.done.wait(5)
    stream.stop()
    assert media.default_registry.get("w") is client


# security: credentials, external images, deadline, cache

KEY = ("bot@example.com", "SECRETKEY")


def test_http_upload_url_never_gets_credentials(tmp_path):
    url = "http://chat.example.com/user_uploads/1/a/x.png"
    net = Net({url: ("image/png", PNG)})
    resolver(tmp_path, net).image_for(msg(f"![x]({url})"))
    assert all(c[1] is None for c in net.calls)


def test_other_port_never_gets_credentials(tmp_path):
    url = "https://chat.example.com:8443/user_uploads/1/a/x.png"
    net = Net({url: ("image/png", PNG)})
    resolver(tmp_path, net).image_for(msg(f"![x]({url})"))
    assert all(c[1] is None for c in net.calls)


def test_non_upload_path_on_server_gets_no_credentials(tmp_path):
    net = Net({"https://chat.example.com/json/users/me": ("image/png", PNG)})
    resolver(tmp_path, net).image_for(msg("![](/json/users/me)"))
    assert all(c[1] is None for c in net.calls)


@pytest.mark.parametrize("path", ["/user_uploads/1/a/x.png", "/user_avatars/1.png",
                                  "/thumbnail?url=a&size=full"])
def test_allowed_server_paths_get_credentials(path):
    base = "https://chat.example.com/"
    assert media.credentials_allowed("https://chat.example.com" + path, base)


@pytest.mark.parametrize("url", [
    "http://chat.example.com/user_uploads/1/a",
    "https://chat.example.com:444/user_uploads/1/a",
    "https://chat.example.com/api/v1/users",
    "https://chat.example.com/user_uploadsX/1",
    "https://evil.org/user_uploads/1/a",
])
def test_credentials_disallowed(url):
    assert not media.credentials_allowed(url, "https://chat.example.com/")


def test_http_base_allows_http_same_origin():
    assert media.credentials_allowed("http://localhost:9991/user_uploads/1/a", "http://localhost:9991")


def test_http_get_drops_auth_on_https_to_http_downgrade_same_host():
    calls = []

    def get(url, **kw):
        calls.append((url, kw.get("auth")))
        if url.startswith("https:"):
            return Resp(302, {"location": "http://chat.example.com/user_uploads/1/a/x.png"})
        return Resp()

    media.http_get(
        "https://chat.example.com/user_uploads/1/a/x.png", auth=KEY,
        auth_base="https://chat.example.com/", timeout=1, max_bytes=100, _get=get,
    )
    assert calls[0][1] == KEY
    assert calls[1][1] is None


def test_http_get_drops_auth_on_redirect_to_other_path():
    calls = []

    def get(url, **kw):
        calls.append((url, kw.get("auth")))
        if "user_uploads" in url:
            return Resp(302, {"location": "/json/users/me"})
        return Resp()

    media.http_get(
        "https://chat.example.com/user_uploads/1/a/x.png", auth=KEY,
        auth_base="https://chat.example.com/", timeout=1, max_bytes=100, _get=get,
    )
    assert calls[1][1] is None


def test_external_images_off_skips_foreign_hosts(tmp_path):
    net = Net({"https://x.com/a.png": ("image/png", PNG)})
    r = resolver(tmp_path, net, external_images=False)
    assert r.image_for(msg("![p](https://x.com/a.png)")) is None
    assert net.calls == []


def test_external_images_off_still_fetches_server_uploads_and_avatars(tmp_path):
    up = "https://chat.example.com/user_uploads/1/a/x.png"
    av = "https://secure.gravatar.com/avatar/abc"
    net = Net({up: ("image/png", PNG), av: ("image/png", PNG)})
    r = resolver(tmp_path, net, external_images=False)
    assert r.image_for(msg(f"![p]({up})")) is not None
    assert r.image_for(msg("hi", avatar_url=av)) is not None


def test_external_images_off_skips_foreign_non_gravatar_avatar(tmp_path):
    net = Net({"https://evil.org/me.png": ("image/png", PNG)})
    r = resolver(tmp_path, net, external_images=False)
    assert r.image_for(msg("hi", avatar_url="https://evil.org/me.png")) is None
    assert net.calls == []


def test_external_images_callable_is_read_each_time(tmp_path):
    flag = [False]
    net = Net({"https://x.com/a.png": ("image/png", PNG)})
    r = resolver(tmp_path, net, external_images=lambda: flag[0])
    assert r.image_for(msg("![p](https://x.com/a.png)")) is None
    flag[0] = True
    assert r.image_for(msg("![p](https://x.com/a.png)")) is not None


def test_http_get_checks_deadline_before_redirect_hop():
    calls = []

    def get(url, **kw):
        calls.append(url)
        return Resp(302, {"location": "https://x.com/b"})

    with pytest.raises(HttpError):
        media.http_get("https://x.com/a", timeout=1, max_bytes=10, _get=get,
                       deadline=time_past())
    assert calls == []


def time_past():
    import time
    return time.monotonic() - 1


def test_resolver_shares_one_budget_between_image_and_avatar(tmp_path):
    fake_now = [100.0]
    net = Net({"https://x.com/a.png": HttpError("slow")})

    def slow(*a, **k):
        fake_now[0] += 9  # the image attempt eats the whole budget
        return net(*a, **k)

    r = resolver(tmp_path, slow, clock=lambda: fake_now[0])
    assert r.image_for(msg("![p](https://x.com/a.png)", avatar_url="https://x.com/av.png")) is None
    assert len(net.calls) == 1


def test_recent_cache_files_are_not_pruned(tmp_path):
    r = resolver(tmp_path, Net(), cache_cap_bytes=1)
    r.cache_dir.mkdir(parents=True)
    fresh = r.cache_dir / "fresh.png"
    fresh.write_bytes(b"x" * 100)
    keep = r.cache_dir / "keep.png"
    keep.write_bytes(b"y")
    r._prune(keep=keep)
    assert fresh.exists()
    old = r.cache_dir / "old.png"
    old.write_bytes(b"x" * 100)
    os.utime(old, (1, 1))
    r._prune(keep=keep)
    assert not old.exists() and fresh.exists()


def test_server_avatar_outside_media_paths_is_fetched_without_credentials(tmp_path):
    av = "https://chat.example.com/avatar/5"
    net = Net({av: ("image/png", PNG)})
    r = resolver(tmp_path, net, external_images=False)
    assert r.image_for(msg("hi", avatar_url=av)) is not None
    assert net.calls[0][1] is None
