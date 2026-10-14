import shutil
import subprocess

import pytest

from z_iris.config import Action
from z_iris.message import Message
from z_iris.output import banner_body, banner_command, banner_title, sound_command
from z_iris.pipeline import Notification


ACTION = Action("synth", 60, "full", None)


def channel(content="hello", sender="Ada"):
    return Message(
        "work", "h", 101, "channel", 9, sender, content, frozenset(), 7, "ops",
        "deploys", (),
    )


def dm(ids=(9,)):
    return Message(
        "work", "h", 102, "dm", 9, "Ada", "x", frozenset(), None, None, None,
        tuple(ids),
    )


def test_sound_command_uses_the_vol_effect():
    assert sound_command(("play",), "/a/b.wav", 5) == ["play", "/a/b.wav", "vol", "0.05"]


@pytest.mark.skipif(shutil.which("sox") is None, reason="needs sox")
def test_volume_really_scales_the_signal(tmp_path):
    # The -v input option is ignored for generated input, which once made
    # every rule volume a no-op. Measure the real output instead.
    wav = tmp_path / "t.wav"
    subprocess.run(["sox", "-n", str(wav), "synth", "0.15", "sine", "880"], check=True)
    target = str(wav)

    def peak(volume):
        command = sound_command(("sox",), target, volume)
        command = [*command[:2], "-n", *command[2:]]
        out = subprocess.run([*command, "stat"], capture_output=True, text=True)
        line = next(l for l in out.stderr.splitlines() if "Maximum amplitude" in l)
        return float(line.split()[-1])

    assert peak(100) > 0.9
    assert 0.2 < peak(25) < 0.3


def test_titles():
    assert banner_title(channel()) == "Ada (#ops > deploys)"
    assert banner_title(dm()) == "Ada"
    assert banner_title(dm((3, 12))) == "Ada (group)"


def test_body_collapses_whitespace_and_truncates():
    assert banner_body(channel("a\n\n  b\tc")) == "a b c"
    body = banner_body(channel("x" * 5000))
    assert len(body) == 200 and body.endswith("…")
    assert banner_body(channel("")) == "(no text)"
    assert banner_body(channel("   \n ")) == "(no text)"


def test_body_that_looks_like_an_option_is_neutralised():
    assert not banner_body(channel("-open evil")).startswith("-")
    assert "-open evil" in banner_body(channel("-open evil"))


def test_banner_command_is_argv_only():
    n = Notification(channel("-open x"), "zulip://h/#narrow/x", "mention", ACTION)
    command = banner_command("terminal-notifier", n)
    assert command[0] == "terminal-notifier"
    assert command[command.index("-open") + 1] == "zulip://h/#narrow/x"
    assert command[command.index("-group") + 1] == "z-iris-work-101"
    assert command[command.index("-title") + 1] == "Ada (#ops > deploys)"
    assert not command[command.index("-message") + 1].startswith("-")


def test_title_that_looks_like_an_option_is_neutralised():
    n = Notification(channel(sender="-sound x"), "zulip://h/#narrow/x", "dm", ACTION)
    command = banner_command("terminal-notifier", n)
    assert not command[command.index("-title") + 1].startswith("-")


def test_spawn_reports_a_failing_command(capsys):
    import sys

    from z_iris.output import _spawn

    thread = _spawn([sys.executable, "-c", "import sys; sys.stderr.write('nope'); sys.exit(3)"])
    thread.join(5)
    err = capsys.readouterr().err
    assert "exit 3" in err and "nope" in err


def test_spawn_reports_a_missing_binary(capsys):
    from z_iris.output import _spawn

    assert _spawn(["definitely-not-a-real-binary-xyz"]) is None
    assert "cannot run definitely-not-a-real-binary-xyz" in capsys.readouterr().err


import pytest


@pytest.mark.parametrize("text", ["(running late)", "{x}", "<b>", '"quoted"', "[a]", "'q'"])
def test_text_that_looks_like_a_property_list_is_neutralised(text):
    # terminal-notifier reads option values through NSUserDefaults, which
    # parses "(a, b)" as an array and "{...}" as a dictionary.
    n = Notification(channel(text, sender=text), "zulip://h/#narrow/x", "dm", ACTION)
    command = banner_command("terminal-notifier", n)
    for flag in ("-title", "-message"):
        value = command[command.index(flag) + 1]
        assert value[0] == "\u200b" and text in value


from z_iris.config import parse_config
from z_iris.output import DryRunOutput, RealOutput
from z_iris.settings import Settings

CONFIG = parse_config('[[server]]\nname = "work"\nzuliprc = "/x"\n')


def deliver(action, capture):
    n = Notification(channel(), "zulip://h/#narrow/x", "rule", action)
    out = RealOutput(Settings(CONFIG), spawn=capture.append)
    out.deliver(n)
    out.drain()


def test_rule_sound_and_volume_reach_the_player():
    calls = []
    deliver(Action("/a/b.wav", 25, "full", "r"), calls)
    banner = next(c for c in calls if c[0] == "terminal-notifier")
    sound = next(c for c in calls if c[0] == "play")
    assert sound == ["play", "-q", "/a/b.wav", "vol", "0.25"]


@pytest.mark.parametrize("action", [Action("none", 60, "full", "r"), Action("synth", 0, "full", "r")])
def test_no_sound_means_no_player(action):
    calls = []
    deliver(action, calls)
    assert len(calls) == 1 and calls[0][0] == "terminal-notifier"


def test_banner_off_skips_the_banner():
    calls = []
    deliver(Action("synth", 60, "off", "r"), calls)
    assert len(calls) == 1 and calls[0][0] == "play"


def test_title_banner_hides_the_message_text():
    calls = []
    deliver(Action("none", 0, "title", "r"), calls)
    command = calls[0]
    assert command[command.index("-message") + 1] == "New message"
    assert command[command.index("-title") + 1] == "Ada (#ops > deploys)"


def test_dry_run_names_the_rule_and_volume(capsys):
    n = Notification(channel(), "zulip://h/#narrow/x", "rule", Action("synth", 33, "full", "ops"))
    DryRunOutput(Settings(CONFIG)).deliver(n)
    out = capsys.readouterr().out
    assert "rule ops" in out and "vol 0.33" in out
    n = Notification(channel(), "zulip://h/#narrow/x", "dm", ACTION)
    DryRunOutput(Settings(CONFIG)).deliver(n)
    assert "rule default" in capsys.readouterr().out


def test_output_steps_can_be_called_separately():
    calls = []
    n = Notification(channel(), "zulip://h/#narrow/x", "rule", Action("/a/b.wav", 50, "full", "r", flash="top"))
    out = RealOutput(Settings(CONFIG), spawn=calls.append)
    flashes = []
    out.visual = type("V", (), {"flash": lambda self, action: flashes.append(action.flash)})()
    out.banner(n)
    out.drain()
    assert [c[0] for c in calls] == ["terminal-notifier"]
    out.sound(n)
    assert calls[-1][-2:] == ["vol", "0.50"]
    out.sound(n, volume=80)
    assert calls[-1][-2:] == ["vol", "0.80"]
    out.flash(n)
    assert flashes == ["top"]
    calls.clear(); flashes.clear()
    out.deliver(n)
    out.drain()
    assert len(calls) == 2 and flashes == ["top"]


def test_banner_body_shows_plain_text_with_emoji():
    assert banner_body(channel("**Deploy** done :tada: see [log](https://x.y/z)")) == "Deploy done 🎉 see log"
class FakeNotifier:
    def __init__(self):
        self.shown, self.cleared = [], []

    def show(self, title, body, url, image=None, group=None, silent=True):
        self.shown.append((title, body, url, image, group, silent))

    def clear(self, group):
        self.cleared.append(group)


def native(action, image_for=None, content="hello"):
    fake = FakeNotifier()
    out = RealOutput(Settings(CONFIG), spawn=lambda c: None, notifier=fake, image_for=image_for)
    out.banner(Notification(channel(content), "zulip://h/#narrow/x", "rule", action))
    out.drain()
    return fake.shown


def test_banner_goes_to_the_notifier_with_plain_text():
    (shown,) = native(Action("none", 0, "full", "r"), content="-not an option")
    assert shown == (
        "Ada (#ops > deploys)", "-not an option", "zulip://h/#narrow/x", None,
        "z-iris-work-101", True,
    )


def test_title_mode_hides_text_and_skips_the_image(tmp_path):
    calls = []
    (shown,) = native(
        Action("none", 0, "title", "r"), image_for=lambda m: calls.append(m) or tmp_path
    )
    assert shown[1] == "New message" and shown[3] is None and not calls


def test_banner_off_shows_nothing():
    assert native(Action("none", 0, "off", "r")) == []


def test_image_for_supplies_the_attachment(tmp_path):
    image = tmp_path / "a.png"
    (shown,) = native(Action("none", 0, "full", "r"), image_for=lambda m: image)
    assert shown[3] == image


def test_a_failing_image_lookup_still_shows_the_banner(capsys):
    def boom(message):
        raise OSError("disk")

    (shown,) = native(Action("none", 0, "full", "r"), image_for=boom)
    assert shown[3] is None and "image lookup failed" in capsys.readouterr().err


def test_outside_the_bundle_the_default_is_terminal_notifier():
    from z_iris.output import TerminalNotifier, make_notifier

    assert isinstance(make_notifier(), TerminalNotifier)  # tests never run in the bundle


def test_terminal_notifier_clear_uses_remove():
    from z_iris.output import TerminalNotifier

    calls = []
    TerminalNotifier(calls.append).clear("g")
    assert calls == [["terminal-notifier", "-remove", "g"]]


def test_a_custom_notifier_setting_is_ignored_with_a_warning(capsys):
    config = parse_config(
        '[[server]]\nname = "work"\nzuliprc = "/x"\n[output]\nnotifier = "/x/tn"\n'
    )
    RealOutput(Settings(config), spawn=lambda c: None, notifier=FakeNotifier())
    assert "notifier is ignored" in capsys.readouterr().err


def test_menubar_icon_falls_back_to_text_when_missing(tmp_path):
    from z_iris.menubar import menubar_icon

    assert menubar_icon(tmp_path / "nope.png") is None
    assert menubar_icon().endswith("z-iris-menubarTemplate.png")


def test_a_batch_summary_title_replaces_the_sender_title():
    n = Notification(channel(), "zulip://h/#narrow/x", "rule", ACTION, summary="3 new in #ops")
    command = banner_command("terminal-notifier", n)
    assert command[command.index("-title") + 1] == "3 new in #ops"


def test_banner_returns_at_once_while_the_image_is_fetched():
    import threading

    gate, started = threading.Event(), threading.Event()

    def slow(message):
        started.set()
        assert gate.wait(5)
        return None

    fake = FakeNotifier()
    out = RealOutput(Settings(CONFIG), spawn=lambda c: None, notifier=fake, image_for=slow)
    n = Notification(channel(), "zulip://h/#narrow/x", "rule", Action("none", 0, "full", "r"))
    out.banner(n)  # must not wait for the fetch
    assert started.wait(5) and fake.shown == []
    gate.set()
    out.drain()
    assert len(fake.shown) == 1
    out.close()


def test_banners_keep_their_order_and_close_does_not_hang():
    import threading

    gate = threading.Event()
    fake = FakeNotifier()
    out = RealOutput(
        Settings(CONFIG), spawn=lambda c: None, notifier=fake,
        image_for=lambda m: gate.wait(5) and None,
    )
    for text in ("one", "two", "three"):
        out.banner(Notification(channel(text), "u", "rule", Action("none", 0, "full", "r")))
    gate.set()
    out.drain()
    assert [s[1] for s in fake.shown] == ["one", "two", "three"]
    blocker = threading.Event()
    stuck = RealOutput(
        Settings(CONFIG), spawn=lambda c: None, notifier=FakeNotifier(),
        image_for=lambda m: blocker.wait(30),
    )
    stuck.banner(Notification(channel(), "u", "rule", Action("none", 0, "full", "r")))
    stuck.close(timeout=0.2)  # returns although the worker is stuck
    blocker.set()
