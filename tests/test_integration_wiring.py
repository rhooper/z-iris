from types import SimpleNamespace

from z_iris.config import parse_config
from z_iris.settings import Settings
from z_iris.webui import EditorServer


def test_real_output_gets_an_image_resolver(monkeypatch):
    from z_iris import __main__ as entry

    config = parse_config('[[server]]\nname = "w"\nzuliprc = "/x"\n')
    output = entry._real_output(Settings(config))
    assert callable(output.image_for)


def test_editor_flasher_accepts_the_action_dict_shape():
    seen = []
    visual = SimpleNamespace(flash=lambda action: seen.append(
        (action.flash, action.flash_color, action.flash_seconds)))
    flasher = lambda action: visual.flash(SimpleNamespace(**action))  # as menubar wires it
    flasher({"flash": "top", "flash_color": "#ff0000", "flash_seconds": 1.0})
    assert seen == [("top", "#ff0000", 1.0)]
