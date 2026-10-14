import os
import sys
import threading
import time

from z_iris.reloader import run, snapshot


def wait_for(predicate, seconds=10):
    end = time.time() + seconds
    while time.time() < end:
        if predicate():
            return True
        time.sleep(0.02)
    return False


def touch(path, text):
    path.write_text(text)
    stat = path.stat()
    os.utime(path, (stat.st_atime, stat.st_mtime + 5 + time.time() % 100))


def child(log, code="import time; time.sleep(60)"):
    script = f"open({str(log)!r}, 'a').write('start\\n'); {code}"
    return [sys.executable, "-c", script]


def starts(log):
    return log.read_text().count("start") if log.exists() else 0


def start(command, root, messages=None):
    stop = threading.Event()
    result = []
    thread = threading.Thread(
        target=lambda: result.append(
            run(command, root, poll=0.05, settle=0.05, stop=stop.is_set,
                out=(messages.append if messages is not None else (lambda _m: None)))
        )
    )
    thread.start()
    return stop, thread, result


def test_snapshot_lists_only_watched_files(tmp_path):
    (tmp_path / "a.py").write_text("x")
    (tmp_path / "b.html").write_text("x")
    (tmp_path / "c.txt").write_text("x")
    (tmp_path / "__pycache__").mkdir()
    (tmp_path / "__pycache__" / "d.py").write_text("x")
    assert {p.name for p in snapshot(tmp_path)} == {"a.py", "b.html"}


def test_a_source_change_restarts_the_child_once(tmp_path):
    src, log = tmp_path / "src", tmp_path / "log"
    src.mkdir()
    (src / "m.py").write_text("1")
    stop, thread, _ = start(child(log), src)
    try:
        assert wait_for(lambda: starts(log) == 1)
        touch(src / "m.py", "2")
        assert wait_for(lambda: starts(log) == 2)
        time.sleep(0.4)
        assert starts(log) == 2
    finally:
        stop.set()
        thread.join(10)
    assert not thread.is_alive()


def test_a_clean_exit_ends_the_run(tmp_path):
    src, log = tmp_path / "src", tmp_path / "log"
    src.mkdir()
    stop, thread, result = start(child(log, "pass"), src)
    thread.join(10)
    assert result == [0]


def test_a_crash_waits_for_the_next_change_then_restarts(tmp_path):
    src, log = tmp_path / "src", tmp_path / "log"
    src.mkdir()
    (src / "m.py").write_text("1")
    messages = []
    stop, thread, _ = start(child(log, "raise SystemExit(3)"), src, messages)
    try:
        assert wait_for(lambda: any("exited with 3" in m for m in messages))
        time.sleep(0.3)
        assert starts(log) == 1
        touch(src / "m.py", "2")
        assert wait_for(lambda: starts(log) == 2)
    finally:
        stop.set()
        thread.join(10)


def test_cli_autoreload_flag_is_accepted_and_removed_for_the_child(monkeypatch):
    import z_iris.reloader
    from z_iris.__main__ import main

    seen = {}
    monkeypatch.setattr(
        z_iris.reloader, "run", lambda command, root, **kw: seen.update(command=command, root=root) or 0
    )
    assert main(["--autoreload", "--headless"]) == 0
    assert seen["command"][1:] == ["-m", "z_iris", "--headless"]
    assert (seen["root"] / "reloader.py").exists()
