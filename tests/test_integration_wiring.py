from types import SimpleNamespace

from z_iris.config import parse_config
from z_iris.settings import Settings
from z_iris.webui import EditorServer


def test_real_output_gets_an_image_resolver(monkeypatch):
    from z_iris import __main__ as entry

    config = parse_config('[[server]]\nname = "w"\nzuliprc = "/x"\n')
    output = entry._real_output(Settings(config))
    assert callable(output.image_for)


def test_real_output_passes_external_images_setting(monkeypatch):
    from z_iris import __main__ as entry
    from z_iris import media

    seen = []
    real = media.ImageResolver.__init__

    def spy(self, *a, **k):
        seen.append(k.get("external_images"))
        real(self, *a, **k)

    monkeypatch.setattr(media.ImageResolver, "__init__", spy)
    config = parse_config(
        '[[server]]\nname = "w"\nzuliprc = "/x"\n[output]\nexternal_images = true\n'
    )
    entry._real_output(Settings(config))
    assert seen and seen[0]() is True


def test_editor_flasher_accepts_the_action_dict_shape():
    seen = []
    visual = SimpleNamespace(flash=lambda action: seen.append(
        (action.flash, action.flash_color, action.flash_seconds)))
    flasher = lambda action: visual.flash(SimpleNamespace(**action))  # as menubar wires it
    flasher({"flash": "top", "flash_color": "#ff0000", "flash_seconds": 1.0})
    assert seen == [("top", "#ff0000", 1.0)]


def _bundle(monkeypatch, inside, days=None):
    from z_iris import __main__ as entry
    from z_iris import output

    monkeypatch.setattr(entry, "in_bundle", lambda: inside)
    monkeypatch.setattr(output, "in_bundle", lambda: inside)
    monkeypatch.setattr(entry, "profile_days_left", lambda app, now: days)
    warnings = []
    monkeypatch.setattr(entry, "log_problem", warnings.append)
    config = parse_config('[[server]]\nname = "w"\nzuliprc = "/x"\n')
    return entry._real_output(Settings(config)), warnings


def test_bundle_output_has_a_priority_notifier(monkeypatch):
    from z_iris.prioritylink import PriorityNotifier

    out, warnings = _bundle(monkeypatch, True)
    assert isinstance(out.priority, PriorityNotifier)
    assert out.priority.fallback is out.notifier
    assert warnings == []
    out.close()


def test_outside_the_bundle_there_is_no_priority_notifier(monkeypatch):
    out, _ = _bundle(monkeypatch, False)
    assert out.priority is None


def test_an_expiring_profile_is_warned_at_startup(monkeypatch):
    out, warnings = _bundle(monkeypatch, True, days=1.5)
    assert len(warnings) == 1 and "expires in 1.5 days" in warnings[0]
    out.close()
    _, quiet = _bundle(monkeypatch, True, days=30)
    assert quiet == []
