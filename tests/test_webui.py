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
    assert json.loads(data)["rules"][0]["description"] == "old"
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
    assert settings.config.rules[0].label == "bots"
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


def test_preview_runs_the_draft_not_the_saved_rules(tmp_path):
    from z_iris.preview import PreviewSource
    from tests.test_preview import FakeClient, stream_message

    path = tmp_path / "config.toml"
    path.write_text(TEXT)
    settings = Settings(load_config(path), path)
    source = PreviewSource(lambda _rc: FakeClient([stream_message(1, channel="ci")]))
    server = EditorServer(settings, path, spawn=lambda c: None, preview_source=source)
    url = server.start()
    host, port = server.address
    token = url.rstrip("/").rsplit("/", 1)[1]
    try:
        def post(body):
            conn = http.client.HTTPConnection(host, port, timeout=5)
            conn.request("POST", f"/{token}/api/preview", json.dumps(body),
                         {"Host": f"127.0.0.1:{port}", "Content-Type": "application/json"})
            r = conn.getresponse()
            return r.status, json.loads(r.read())

        draft = [{"name": "ci", "match": "channel", "channel": "ci", "volume": 40}]
        status, data = post({"rules": draft})
        entry = data["servers"][0]["messages"][0]
        assert status == 200 and (entry["rule_index"], entry["volume"]) == (0, 40)
        assert path.read_text() == TEXT  # nothing saved
        status, data = post({"rules": [{"name": "x", "match": "mention", "volume": 500}]})
        assert status == 400 and "volume" in data["error"]
    finally:
        server.stop()


def test_channels_endpoint_lists_every_channel_busiest_first(tmp_path):
    from pathlib import Path

    from z_iris.channels import ChannelSource

    class C:
        def get_streams(self, **kwargs):  # dev is busier, so it comes first
            return {"result": "success", "streams": [
                {"name": "ops", "stream_weekly_traffic": 3},
                {"name": "dev", "stream_weekly_traffic": 90}]}

    path = tmp_path / "config.toml"
    path.write_text(TEXT)
    server = EditorServer(Settings(load_config(path), path), path,
                          channel_source=ChannelSource(lambda _rc: C()))
    url = server.start()
    host, port = server.address
    token = url.rstrip("/").rsplit("/", 1)[1]
    try:
        conn = http.client.HTTPConnection(host, port, timeout=5)
        conn.request("GET", f"/{token}/api/channels", headers={"Host": f"127.0.0.1:{port}"})
        r = conn.getresponse()
        data = json.loads(r.read())
        assert r.status == 200 and data["all"] == ["dev", "ops"]
        assert data["servers"][0]["name"] == "work"
    finally:
        server.stop()


def _wav(tmp_path, name="up.wav"):
    import shutil
    import subprocess

    if shutil.which("sox") is None:
        pytest.skip("needs sox")
    wav = tmp_path / name
    subprocess.run(["sox", "-n", str(wav), "synth", "0.1", "sine", "300"], check=True)
    import base64
    return base64.b64encode(wav.read_bytes()).decode()


def test_duplicate_upload_is_rejected_and_nothing_changes(editor, tmp_path):
    call, token, path, *_ = editor
    data = _wav(tmp_path)
    assert call("POST", f"/{token}/api/sounds", {"filename": "Horn.wav", "data": data})[0] == 200
    stored = (path.parent / "sounds" / "Horn.wav").read_bytes()
    for filename in ["horn.wav", "CHIME.wav"]:
        status, body = call("POST", f"/{token}/api/sounds", {"filename": filename, "data": data})
        assert status == 400 and "already" in json.loads(body)["error"]
    assert (path.parent / "sounds" / "Horn.wav").read_bytes() == stored


def test_delete_sound_endpoint(editor, tmp_path):
    call, token, path, settings, _ = editor
    data = _wav(tmp_path)
    call("POST", f"/{token}/api/sounds", {"filename": "Horn.wav", "data": data})
    call("POST", f"/{token}/api/sounds", {"filename": "Klaxon.wav", "data": data})
    sounds = path.parent / "sounds"
    # bundled and unknown
    for name in ["chime", "nope"]:
        assert call("POST", f"/{token}/api/sounds/delete", {"name": name})[0] == 400
    # used by a rule: refused, names the rule
    rules = [{"name": "alarm rule", "match": "mention", "sound": "Horn"}]
    assert call("PUT", f"/{token}/api/config", {"rules": rules})[0] == 200
    status, body = call("POST", f"/{token}/api/sounds/delete", {"name": "Horn"})
    assert status == 400 and "alarm rule" in json.loads(body)["error"]
    assert (sounds / "Horn.wav").exists()
    # used as the default sound
    call("PUT", f"/{token}/api/config", {"defaults": {"sound": "Klaxon"}})
    status, body = call("POST", f"/{token}/api/sounds/delete", {"name": "Klaxon"})
    assert status == 400 and "default" in json.loads(body)["error"]
    # unused: deleted, including the original
    call("PUT", f"/{token}/api/config", {"defaults": {"sound": "chime"}, "rules": []})
    assert call("POST", f"/{token}/api/sounds/delete", {"name": "Horn"})[0] == 200
    assert not (sounds / "Horn.wav").exists()
    assert not list((sounds / "originals").glob("Horn.*"))
    _, listing = call("GET", f"/{token}/api/config")
    assert "Horn" not in [s["name"] for s in json.loads(listing)["sounds"]]


def test_flash_without_the_menubar_app_is_a_clear_400(editor):
    call, token, *_ = editor
    body = {"flash": "top", "flash_color": "#ff0000", "flash_seconds": 1.5}
    status, data = call("POST", f"/{token}/api/flash", body)
    assert status == 400
    assert "flash is only available in the menubar app" in json.loads(data)["error"]


def test_flash_endpoint_validates_input(editor):
    call, token, *_ = editor
    for bad in [{"flash": "sideways"}, {"flash": "top", "flash_color": "red"},
                {"flash": "top", "flash_seconds": -1}, {"flash": "top", "flash_seconds": "x"}]:
        assert call("POST", f"/{token}/api/flash", bad)[0] == 400


def test_flash_endpoint_passes_the_action_dict(tmp_path):
    path = tmp_path / "config.toml"
    path.write_text(TEXT)
    seen = []
    server = EditorServer(Settings(load_config(path), path), path)
    server.flasher = seen.append
    url = server.start()
    host, port = server.address
    token = url.rstrip("/").rsplit("/", 1)[1]
    try:
        conn = http.client.HTTPConnection(host, port, timeout=5)
        conn.request("POST", f"/{token}/api/flash",
                     json.dumps({"flash": "left", "flash_color": "#00ff00", "flash_seconds": 2}),
                     {"Host": f"127.0.0.1:{port}", "Content-Type": "application/json"})
        assert conn.getresponse().status == 200
        assert seen == [{"flash": "left", "flash_color": "#00ff00", "flash_seconds": 2}]
    finally:
        server.stop()


def test_config_includes_focus(editor):
    call, token, *_ = editor
    _, data = call("GET", f"/{token}/api/config")
    assert json.loads(data)["focus"]["mode"] == "off"


def test_removing_a_used_sound_lists_its_users_then_replaces_it(editor, tmp_path):
    call, token, path, settings, _ = editor
    data = _wav(tmp_path)
    call("POST", f"/{token}/api/sounds", {"filename": "Horn.wav", "data": data})
    rules = [{"name": "alarm rule", "match": "mention", "sound": "Horn"},
             {"name": "quiet", "match": "dm", "sound": "bell"}]
    call("PUT", f"/{token}/api/config", {"rules": rules, "defaults": {"sound": "Horn"}})
    sounds = path.parent / "sounds"

    status, body = call("POST", f"/{token}/api/sounds/delete", {"name": "Horn"})
    assert status == 400 and json.loads(body)["used_by"] == ["default sound", "alarm rule"]
    for bad in ["nope", "Horn"]:
        status, _ = call("POST", f"/{token}/api/sounds/delete",
                         {"name": "Horn", "replacement": bad})
        assert status == 400
    assert (sounds / "Horn.wav").exists()

    status, _ = call("POST", f"/{token}/api/sounds/delete",
                     {"name": "Horn", "replacement": "dx-epiano"})
    assert status == 200 and not (sounds / "Horn.wav").exists()
    config = load_config(path)
    assert config.sound == "dx-epiano"
    assert [r.sound for r in config.rules] == ["dx-epiano", "bell"]
    assert settings.config.sound == "dx-epiano"  # live settings reloaded


def test_a_used_sound_can_be_replaced_by_none(editor, tmp_path):
    call, token, path, _, _ = editor
    call("POST", f"/{token}/api/sounds", {"filename": "Horn.wav", "data": _wav(tmp_path)})
    call("PUT", f"/{token}/api/config", {"rules": [{"name": "r", "match": "dm", "sound": "Horn"}]})
    status, _ = call("POST", f"/{token}/api/sounds/delete", {"name": "Horn", "replacement": "none"})
    assert status == 200 and load_config(path).rules[0].sound == "none"


def test_the_page_ignores_a_query_string(editor):
    call, token, *_ = editor
    status, body = call("GET", f"/{token}/?expand")
    assert status == 200 and b"<html" in body
    assert call("GET", f"/{token}/api/config?x=1")[0] == 200
