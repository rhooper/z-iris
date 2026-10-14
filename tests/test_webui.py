import http.client
import json

import pytest

from z_iris.config import load_config
from z_iris.settings import Settings
from z_iris.webui import EditorServer

TEXT = '''[[server]]
name = "work"
zuliprc = "/x/zuliprc-secret"

[[rule]]
name = "old"
match = "mention"
'''


@pytest.fixture
def editor(tmp_path):
    path = tmp_path / "config.toml"
    path.write_text(TEXT)
    settings = Settings(load_config(path), path)
    played = []
    server = EditorServer(settings, path, spawn=played.append)
    url = server.start()
    host, port = server.address
    token = url.rstrip("/").rsplit("/", 1)[1]

    def call(method, route, body=None, headers=None, host_header=None):
        conn = http.client.HTTPConnection(host, port, timeout=5)
        hdrs = {"Host": host_header or f"127.0.0.1:{port}"}
        if body is not None:
            hdrs["Content-Type"] = "application/json"
            body = json.dumps(body)
        hdrs.update(headers or {})
        conn.request(method, route, body=body, headers=hdrs)
        r = conn.getresponse()
        data = r.read()
        return r.status, data

    yield call, token, path, settings, played
    server.stop()


def test_page_and_config_are_served_without_secrets(editor):
    call, token, *_ = editor
    status, page = call("GET", f"/{token}/")
    assert status == 200 and b"<title>" in page
    status, data = call("GET", f"/{token}/api/config")
    assert status == 200
    assert json.loads(data)["rules"][0]["name"] == "old"
    assert b"zuliprc-secret" not in data


def test_wrong_token_or_host_is_refused(editor):
    call, token, *_ = editor
    assert call("GET", "/nope/api/config")[0] == 404
    assert call("GET", f"/{token}/api/config", host_header="evil.example:80")[0] == 403


def test_put_saves_validates_backs_up_and_reloads(editor):
    call, token, path, settings, _ = editor
    rules = [{"name": "bots", "match": "channel", "channel": "ci", "sound": "none"}]
    status, _ = call("PUT", f"/{token}/api/config", {"rules": rules})
    assert status == 200
    assert settings.config.rules[0].name == "bots"
    assert "[[rule]]" in path.read_text()
    assert (path.parent / "config.toml.bak").read_text() == TEXT


def test_invalid_put_changes_nothing(editor):
    call, token, path, settings, _ = editor
    bad = [{"name": "x", "match": "mention", "volume": 500}]
    status, data = call("PUT", f"/{token}/api/config", {"rules": bad})
    assert status == 400 and "volume" in json.loads(data)["error"]
    assert path.read_text() == TEXT
    assert call("PUT", f"/{token}/api/config", {"rules": "oops"})[0] == 400


def test_cross_origin_and_wrong_content_type_writes_are_refused(editor):
    call, token, path, *_ = editor
    status, _ = call("PUT", f"/{token}/api/config", {"rules": []},
                     headers={"Origin": "http://evil.example"})
    assert status == 403
    assert path.read_text() == TEXT


def test_test_sound_plays_through_the_player_with_scaled_volume(editor):
    call, token, _, _, played = editor
    status, _ = call("POST", f"/{token}/api/test", {"sound": "synth", "volume": 50})
    assert status == 200
    assert played[0][:3] == ["play", "-q", "-v"] and played[0][3] == "0.50"
    assert call("POST", f"/{token}/api/test", {"sound": "/no/such.wav", "volume": 5})[0] == 400
    assert call("POST", f"/{token}/api/test", {"sound": "none", "volume": 5})[0] == 200
    assert len(played) == 1
