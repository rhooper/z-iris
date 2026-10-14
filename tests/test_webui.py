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
    status, _ = call("POST", f"/{token}/api/test", {"sound": "chime", "volume": 50})
    assert status == 200
    assert played[0][-2:] == ["vol", "0.50"]
    assert call("POST", f"/{token}/api/test", {"sound": "nosuchsound", "volume": 5})[0] == 400
    assert call("POST", f"/{token}/api/test", {"sound": "none", "volume": 5})[0] == 200
    assert len(played) == 1


def test_config_lists_sound_choices(editor):
    call, token, *_ = editor
    _, data = call("GET", f"/{token}/api/config")
    names = {s["name"]: s["yours"] for s in json.loads(data)["sounds"]}
    assert names["bell"] is False and "synth" not in names


def test_upload_adds_a_sound_that_can_then_be_used_and_tested(editor, tmp_path):
    import base64
    import shutil
    import subprocess

    if shutil.which("sox") is None:
        pytest.skip("needs sox")
    call, token, path, settings, played = editor
    wav = tmp_path / "up.wav"
    subprocess.run(["sox", "-n", str(wav), "synth", "0.1", "sine", "300"], check=True)
    body = {"filename": "My Horn.wav", "data": base64.b64encode(wav.read_bytes()).decode()}
    status, data = call("POST", f"/{token}/api/sounds", body)
    assert status == 200 and json.loads(data)["name"] == "My Horn"
    assert (path.parent / "sounds" / "My Horn.wav").is_file()
    _, listing = call("GET", f"/{token}/api/config")
    assert {"name": "My Horn", "yours": True} in json.loads(listing)["sounds"]
    assert call("POST", f"/{token}/api/test", {"sound": "My Horn", "volume": 40})[0] == 200
    rules = [{"name": "r", "match": "mention", "sound": "My Horn"}]
    assert call("PUT", f"/{token}/api/config", {"rules": rules})[0] == 200


def test_bad_uploads_are_rejected(editor):
    call, token, *_ = editor
    for body in [{"filename": "../x.wav", "data": "AAAA"}, {"filename": "a.wav", "data": "!!"},
                 {"filename": "a.wav"}, {"filename": "a.exe", "data": "AAAA"}]:
        assert call("POST", f"/{token}/api/sounds", body)[0] == 400
