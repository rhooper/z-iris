import pytest


@pytest.fixture(autouse=True)
def _no_real_log_file(tmp_path, monkeypatch):
    """Tests never write ~/Library/Logs/z-iris.log."""
    import z_iris.notify as notify

    monkeypatch.setattr(notify, "LOG_PATH", tmp_path / "z-iris-test.log")
