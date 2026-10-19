import pytest

from z_iris.plaintext import plain_text


@pytest.mark.parametrize(
    "markdown, expected",
    [
        ("**bold** and __bold__ and *it* and _it_ and ~~gone~~", "bold and bold and it and it and gone"),
        ("use `code` here", "use code here"),
        ("snake_case_name stays", "snake_case_name stays"),
        ("2 * 3 * 4", "2 * 3 * 4"),
        ("[the docs](https://example.com/x) rock", "the docs rock"),
        ("![diagram](https://example.com/a.png)", "🖼 diagram"),
        ("![](https://example.com/a.png)", "🖼 image"),
        ("[report.pdf](/user_uploads/1/ab/report.pdf)", "📎 report.pdf"),
        ("hi @**Ada Lovelace** and @**Bob|12**", "hi @Ada Lovelace and @Bob"),
        ("@_**Ada** said", "Ada said"),
        ("@*backend* look", "@backend look"),
        ("@**all** heads up", "@all heads up"),
        ("see #**ops>deploys** and #**dev**", "see #ops > deploys and #dev"),
        ("# Title\ntext", "Title text"),
        ("> quoted line\nreply", "quoted line reply"),
        ("- one\n- two\n1. three", "• one • two 1. three"),
        ("a\n\n---\n\nb", "a b"),
        ("nice :tada: :+1: :octopus:", "nice 🎉 👍 🐙"),
        # Zulip's own names, and Zulip's meaning where it differs (:smile: is 🙂).
        (":working_on_it: :check: :upside_down: :smile:", "🛠 ✅ 🙃 🙂"),
        # Names only the emoji package knows still expand.
        (":white_check_mark: :face_with_tears_of_joy:", "✅ 😂"),
        ("custom :party_parrot: stays", "custom :party_parrot: stays"),
        ("10:30:45 and a:b:c stay", "10:30:45 and a:b:c stay"),
        (":tada::tada: (:octopus:)", "🎉🎉 (🐙)"),
        ("```python\nprint(1)\nx = 2\n```", "print(1) x = 2"),
        ("before ```quote\nthey said hi\n``` after", "before they said hi after"),
        ("```spoiler Plot twist\nthe butler did it\n```", "[spoiler: Plot twist]"),
        ("```spoiler\nsecret\n```", "[spoiler]"),
        ("```math\nE = mc^2\n```", "E = mc^2"),
        ("  lots   of\t space \n\n\n and lines ", "lots of space and lines"),
        ("<time:2024-01-01T10:00:00Z> meeting", "meeting"),
        ("", ""),
    ],
)
def test_markdown_becomes_plain_text(markdown, expected):
    assert plain_text(markdown) == expected


def test_never_raises_on_odd_input():
    for text in ["**", "[", "](", "![](", "```", ":::", "@**", "#**>", "*" * 5000, "_" * 5000]:
        assert isinstance(plain_text(text), str)


def test_long_input_is_handled_quickly():
    import time

    start = time.time()
    plain_text(("**a** [b](c) :smile: `d` " * 5000))
    assert time.time() - start < 2
