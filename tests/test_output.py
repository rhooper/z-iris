from z_iris.message import Message
from z_iris.output import banner_body, banner_command, banner_title, sound_command
from z_iris.pipeline import Notification


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


def test_sound_command_for_synth_and_files():
    assert sound_command(("play", "-q"), "synth", 60) == [
        "play", "-q", "-v", "0.60", "-n", "synth", "0.15", "sine", "880",
    ]
    assert sound_command(("play",), "/a/b.wav", 5) == ["play", "-v", "0.05", "/a/b.wav"]


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
    n = Notification(channel("-open x"), "zulip://h/#narrow/x", "mention")
    command = banner_command("terminal-notifier", n)
    assert command[0] == "terminal-notifier"
    assert command[command.index("-open") + 1] == "zulip://h/#narrow/x"
    assert command[command.index("-group") + 1] == "z-iris-work-101"
    assert command[command.index("-title") + 1] == "Ada (#ops > deploys)"
    assert not command[command.index("-message") + 1].startswith("-")


def test_title_that_looks_like_an_option_is_neutralised():
    n = Notification(channel(sender="-sound x"), "zulip://h/#narrow/x", "dm")
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
    n = Notification(channel(text, sender=text), "zulip://h/#narrow/x", "dm")
    command = banner_command("terminal-notifier", n)
    for flag in ("-title", "-message"):
        value = command[command.index(flag) + 1]
        assert value[0] == "\u200b" and text in value
