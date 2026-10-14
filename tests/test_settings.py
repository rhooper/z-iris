import os

from z_iris.config import load_config
from z_iris.settings import Settings

BASE = '[[server]]\nname = "work"\nzuliprc = "/x"\n'


def write(path, text, bump=1):
    path.write_text(text)
    stat = path.stat()
    os.utime(path, (stat.st_atime, stat.st_mtime + bump))


def make(tmp_path, text=BASE):
    path = tmp_path / "config.toml"
    path.write_text(text)
    return path, Settings(load_config(path), path)


def test_valid_edit_is_applied(tmp_path):
    path, settings = make(tmp_path)
    write(path, BASE + "[defaults]\nvolume = 20\n")
    assert settings.reload() is None
    assert settings.config.volume == 20


def test_invalid_edit_keeps_the_old_config_and_recovers(tmp_path):
    path, settings = make(tmp_path, BASE + "[defaults]\nvolume = 20\n")
    write(path, BASE + "[defaults]\nvolume = 500\n", bump=2)
    error = settings.reload()
    assert error and "volume" in error
    assert settings.config.volume == 20
    assert settings.reload() == error  # still shown, not re-parsed
    write(path, BASE + "[defaults]\nvolume = 30\n", bump=4)
    assert settings.reload() is None
    assert settings.config.volume == 30


def test_unchanged_file_is_not_reparsed(tmp_path):
    path, settings = make(tmp_path)
    path.write_text("not toml [[[")  # same mtime as seen at load? force it back
    os.utime(path, (settings._mtime, settings._mtime))
    assert settings.reload() is None
    assert settings.reload(force=True) is not None


def test_server_changes_need_a_restart_but_other_settings_apply(tmp_path):
    path, settings = make(tmp_path)
    write(
        path,
        BASE.replace('"work"', '"other"') + "[defaults]\nvolume = 10\n",
    )
    message = settings.reload()
    assert message == "servers changed, restart z-iris"
    assert [s.name for s in settings.config.servers] == ["work"]
    assert settings.config.volume == 10


def test_a_missing_file_is_an_error_not_a_crash(tmp_path):
    path, settings = make(tmp_path)
    path.unlink()
    assert settings.reload(force=True)
    assert settings.config.servers


def test_wrong_shape_edit_keeps_config_and_error_persists(tmp_path):
    path, settings = make(tmp_path)
    write(path, BASE + '[rule]\nname = "r"\n')
    error = settings.reload()
    assert error
    assert settings.reload() == error
