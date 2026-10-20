import pytest

from z_iris.config import Action, ConfigError, parse_config, resolve_action

BASE = '[[server]]\nname = "work"\nzuliprc = "/x"\n'


def test_builtin_defaults():
    config = parse_config(BASE)
    action = resolve_action(config, "work", None)
    assert (action.flash, action.flash_color, action.flash_seconds) == ("none", "#ff3b30", 0.6)
    assert (action.repeat, action.repeat_every, action.repeat_boost) == (0, 30, 0)
    assert (action.min_gap, action.batch_window) == (0, 0)
    assert config.focus.mode == "off" and config.focus.quiet_hours == ()


def test_defaults_section_and_rule_override():
    config = parse_config(
        BASE + '[defaults]\nmin_gap = 5\nflash = "top"\n'
        + '[[rule]]\nname = "r"\nmatch = "mention"\nflash = "screen"\nrepeat = 3\n'
        + 'repeat_every = 10\nrepeat_boost = 20\nflash_color = "#00ff00"\nflash_seconds = 1.5\n'
        + "batch_window = 8\n"
    )
    plain = resolve_action(config, "work", None)
    assert (plain.min_gap, plain.flash) == (5, "top")
    action = resolve_action(config, "work", config.rules[0])
    assert (action.flash, action.flash_color, action.flash_seconds) == ("screen", "#00ff00", 1.5)
    assert (action.repeat, action.repeat_every, action.repeat_boost) == (3, 10, 20)
    assert (action.min_gap, action.batch_window) == (5, 8)
    assert action.rule == "r"


@pytest.mark.parametrize(
    "line",
    ['flash = "disco"', 'flash_color = "red"', "flash_seconds = 99", "flash_seconds = 0",
     "repeat = 99", "repeat = -1", "repeat_every = 0", "repeat_boost = 101",
     "min_gap = -1", "min_gap = 99999", "batch_window = 301", 'repeat = "x"', "repeat = true"],
)
def test_bad_values_name_the_rule(line):
    with pytest.raises(ConfigError, match="rule 'r'"):
        parse_config(BASE + f'[[rule]]\nname = "r"\nmatch = "mention"\n{line}\n')
    with pytest.raises(ConfigError):
        parse_config(BASE + f"[defaults]\n{line}\n")


def test_focus_section():
    config = parse_config(
        BASE + '[focus]\nmode = "mentions_and_dms"\nquiet_hours = ["22:00-07:00", "13:00-13:30"]\n'
        + 'quiet_mode = "silent"\n'
    )
    assert config.focus.mode == "mentions_and_dms"
    assert config.focus.quiet_hours == ((22 * 60, 7 * 60), (13 * 60, 13 * 60 + 30))
    assert config.focus.quiet_mode == "silent"
    for bad in ('mode = "dnd"', 'quiet_hours = ["25:00-07:00"]', 'quiet_hours = "22:00"',
                'quiet_mode = "loud"'):
        with pytest.raises(ConfigError, match="focus"):
            parse_config(BASE + f"[focus]\n{bad}\n")


def test_action_can_still_be_built_positionally():
    assert Action("none", 0, "off", None).repeat == 0


def test_equal_quiet_hours_are_rejected():
    with pytest.raises(ConfigError, match="focus.*22:00-22:00"):
        parse_config(BASE + '[focus]\nquiet_hours = ["22:00-22:00"]\n')


def test_sticky_is_a_rule_and_default_switch():
    config = parse_config(
        BASE + '[[rule]]\nname = "dms"\nmatch = "dm"\nsticky = true\n'
    )
    assert resolve_action(config, "work", config.rules[0]).sticky is True
    assert resolve_action(config, "work", None).sticky is False
    everywhere = parse_config(BASE + "[defaults]\nsticky = true\n")
    assert resolve_action(everywhere, "work", None).sticky is True


@pytest.mark.parametrize("value", ['"yes"', "1"])
def test_sticky_must_be_a_boolean(value):
    with pytest.raises(ConfigError, match="sticky must be true or false"):
        parse_config(BASE + f'[[rule]]\nname = "r"\nmatch = "dm"\nsticky = {value}\n')
