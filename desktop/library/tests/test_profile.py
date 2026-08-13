"""Tests for per-game settings profiles (profile.py) and the compat.jsonl
`profile` field.  Network-free.

Run:  cd desktop && python3 -m pytest library/tests -q

The parsing rules here MUST match gpParse() in the board firmware —
the board and the database have to read the same blob the same way.  Those
cases are marked "firmware parity".
"""
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))

import pytest  # noqa: E402

from library import compat, profile  # noqa: E402


# ── parsing (firmware parity with gpParse) ──────────────────────────────────

def test_parse_basic():
    assert profile.parse("drive=dos") == {"drive": "dos"}
    assert profile.parse("") == {}


def test_parse_trims_around_key_and_value():
    assert profile.parse("  drive = dos  ") == {"drive": "dos"}


def test_parse_accepts_crlf_and_bare_cr():
    assert profile.parse("a=1\r\nb=2\r\n") == {"a": "1", "b": "2"}
    assert profile.parse("a=1\rb=2") == {"a": "1", "b": "2"}


def test_parse_ignores_comments_and_keyless_lines():
    assert profile.parse("# note\ndrive=dos\njunk") == {"drive": "dos"}


def test_parse_first_occurrence_wins():
    assert profile.parse("drive=dos\ndrive=auto")["drive"] == "dos"


def test_parse_keeps_an_empty_value():
    # "type=" is how a profile says "do not autostart this game"
    assert profile.parse("type=") == {"type": ""}


def test_parse_lowercases_the_key_only():
    assert profile.parse("DRIVE=DOS") == {"drive": "DOS"}


# ── building ────────────────────────────────────────────────────────────────

def test_build_skips_none_and_keeps_a_stable_order():
    assert profile.build(btn="joy2", drive="dos") == "drive=dos\nbtn=joy2"
    assert profile.build(drive=None) == ""


def test_build_round_trips_through_parse():
    blob = profile.build(drive="dos", btn="joy2", type="@boot;run\\r")
    assert profile.parse(blob) == {"drive": "dos", "btn": "joy2",
                                   "type": "@boot;run\\r"}


def test_update_preserves_keys_it_does_not_know():
    # an editor must not silently delete a key a newer firmware wrote
    blob = "drive=dos\ndf0=disk2.adf\nbtn=joy1"
    out = profile.update(blob, {"btn": "joy2"})
    assert profile.parse(out) == {"drive": "dos", "df0": "disk2.adf",
                                  "btn": "joy2"}


def test_update_removes_on_none_and_adds_new_keys():
    assert profile.parse(profile.update("drive=dos\nbtn=joy1",
                                        {"drive": None})) == {"btn": "joy1"}
    assert profile.parse(profile.update("", {"btn": "joy2"})) == {"btn": "joy2"}


def test_kv_key_matches_the_firmware_prefix():
    assert profile.kv_key("pirates.d64") == "g.pirates.d64"


# ── hard errors ─────────────────────────────────────────────────────────────

def test_oversize_profile_is_an_error():
    errs, _ = profile.check("type=" + "x" * 260)
    assert any("255" in e for e in errs)


def test_exactly_255_bytes_is_accepted():
    blob = "type=" + "x" * 250
    assert len(blob) == profile.MAX
    errs, _ = profile.check(blob)
    assert errs == []


def test_line_without_equals_is_an_error():
    errs, _ = profile.check("drive")
    assert any("key=value" in e for e in errs)


def test_unknown_value_for_a_known_setting_is_an_error():
    errs, _ = profile.check("drive=banana")
    assert any("banana" in e for e in errs)
    assert profile.check("drive=dos")[0] == []


def test_every_firmware_token_validates():
    for key, toks in (("drive", profile.DRIVE), ("speed", profile.SPEED),
                      ("btn", profile.BTN)):
        for t in toks:
            assert profile.check(f"{key}={t}")[0] == [], f"{key}={t}"


def test_validate_raises_on_a_hard_error():
    with pytest.raises(profile.ProfileError):
        profile.validate("drive=banana", "x.d64")
    assert profile.validate("drive=dos") == "drive=dos"


# ── the macro ───────────────────────────────────────────────────────────────

def test_the_firmware_default_macro_is_clean():
    # the string GP_DEFAULT_DISC_MACRO expands to in game_profile.h
    errs, warns = profile.check_macro('@boot;load"*",8,1\\r;@load;run\\r')
    assert errs == [] and warns == []


def test_wait_steps():
    assert profile.check_macro("@boot;@load;@1500")[0] == []
    assert profile.check_macro("@nonsense")[0]
    assert profile.check_macro("@99999")[0]          # over 65535 ms
    assert profile.check_macro("@")[0]


def test_unclosed_brace_is_an_error():
    assert profile.check_macro("ab{ret")[0]
    assert profile.check_macro("ab{ret}")[0] == []


def test_unknown_key_name_only_warns():
    errs, warns = profile.check_macro("{nosuchkey}")
    assert errs == []
    assert any("nosuchkey" in w for w in warns)


def test_every_firmware_key_name_is_clean():
    for name in profile.KEYNAMES:
        assert profile.check_macro("{%s}" % name) == ([], []), name


def test_button_steps_are_valid_but_warn_as_not_yet_executed():
    errs, warns = profile.check_macro("#a")
    assert errs == []
    assert any("not executed" in w for w in warns)
    assert profile.check_macro("#fire")[0]           # not a button


def test_escaped_semicolon_does_not_split_a_step():
    # one text step "a;b", not two steps
    assert profile.check_macro("a\\;b") == ([], [])


def test_empty_steps_are_skipped():
    assert profile.check_macro(";;@boot;;") == ([], [])


def test_unknown_escape_warns():
    _errs, warns = profile.check_macro("\\q")
    assert any("not an escape" in w for w in warns)


# ── warnings that must never become errors ──────────────────────────────────

def test_unknown_setting_key_warns_but_passes():
    # a newer firmware may well know it — a hard failure here would stop the
    # database carrying a profile the board understands
    errs, warns = profile.check("df0=disk2.adf")
    assert errs == []
    assert any("df0" in w for w in warns)


def test_inert_keys_warn():
    errs, warns = profile.check("vol=5")
    assert errs == []
    assert any("never applied" in w for w in warns)


def test_describe_is_a_one_liner():
    assert "drive=dos" in profile.describe("drive=dos\nbtn=joy2")
    assert profile.describe("type=") == "autostart=off"
    assert profile.describe("") == "(empty)"


# ── the compat.jsonl field ──────────────────────────────────────────────────

def _tmpdb(lines):
    fd, path = tempfile.mkstemp(suffix=".jsonl")
    with os.fdopen(fd, "w") as fh:
        for obj in lines:
            fh.write(json.dumps(obj) + "\n")
    return path


def test_a_report_may_carry_a_profile():
    path = _tmpdb([{"id": "#42-M", "machine": "c64", "status": "works",
                    "date": "2026-08-04", "profile": "drive=dos"}])
    reports, errors = compat.load(path)
    assert errors == []
    assert reports[0]["profile"] == "drive=dos"
    os.unlink(path)


def test_a_malformed_profile_fails_verification():
    path = _tmpdb([{"id": "#42-M", "machine": "c64", "status": "works",
                    "date": "2026-08-04", "profile": "drive=banana"}])
    with pytest.raises(compat.CompatError):
        compat.load(path, strict=True)
    os.unlink(path)


def test_append_report_writes_and_validates_a_profile():
    fd, path = tempfile.mkstemp(suffix=".jsonl")
    os.close(fd)
    compat.append_report(canon_id=42, sub=None, machine="c64", status="works",
                         profile="drive=dos", by="t", date="2026-08-04",
                         path=path)
    reports, errors = compat.load(path)
    assert errors == [] and reports[0]["profile"] == "drive=dos"
    with pytest.raises(compat.CompatError):
        compat.append_report(canon_id=42, sub=None, machine="c64",
                             status="works", profile="drive=nope",
                             by="t", date="2026-08-04", path=path)
    os.unlink(path)


def test_current_profile_takes_the_newest_that_has_one():
    path = _tmpdb([
        {"id": "#42-M", "machine": "c64", "status": "issues",
         "date": "2026-01-01", "profile": "drive=fastload"},
        {"id": "#42-M", "machine": "c64", "status": "works",
         "date": "2026-02-01", "profile": "drive=dos"},
    ])
    reports, _ = compat.load(path)
    assert compat.current_profile(reports, 42, "c64") == "drive=dos"
    os.unlink(path)


def test_a_later_verdict_without_a_profile_does_not_erase_one():
    # "I retested it" must not silently drop the settings the game needed
    path = _tmpdb([
        {"id": "#42-M", "machine": "c64", "status": "works",
         "date": "2026-01-01", "profile": "drive=dos"},
        {"id": "#42-M", "machine": "c64", "status": "works",
         "date": "2026-06-01"},
    ])
    reports, _ = compat.load(path)
    assert compat.current_profile(reports, 42, "c64") == "drive=dos"
    os.unlink(path)


def test_profiles_are_per_machine():
    path = _tmpdb([
        {"id": "#42-M", "machine": "c64", "status": "works",
         "date": "2026-01-01", "profile": "drive=dos"},
        {"id": "#42-M", "machine": "plus4", "status": "works",
         "date": "2026-01-01", "profile": "btn=joy1"},
    ])
    reports, _ = compat.load(path)
    assert compat.current_profile(reports, 42, "c64") == "drive=dos"
    assert compat.current_profile(reports, 42, "plus4") == "btn=joy1"
    assert compat.current_profile(reports, 42, "c16") is None
    os.unlink(path)


def test_status_line_shows_a_profile():
    path = _tmpdb([{"id": "#42-M", "machine": "c64", "status": "works",
                    "date": "2026-08-04", "profile": "drive=dos"}])
    reports, _ = compat.load(path)
    assert "drive=dos" in compat.status_line(reports[0])
    os.unlink(path)


# ── the macro as steps (what the visual editor edits) ──────────────────────

def test_parse_macro_the_default():
    steps = profile.parse_macro('@boot;load"*",8,1\\r;@load;run\\r')
    assert [(s.kind, s.value) for s in steps] == [
        (profile.WAIT_BOOT, ""), (profile.TEXT, 'load"*",8,1\\r'),
        (profile.WAIT_LOAD, ""), (profile.TEXT, "run\\r")]


def test_parse_macro_waits_keys_and_buttons():
    # the shape a user describes: "3 s after LOAD press C=, 4 s later fire"
    steps = profile.parse_macro("@3000;{c=};@4000;#a;@2000;k")
    assert [(s.kind, s.value) for s in steps] == [
        (profile.WAIT_MS, "3000"), (profile.KEY, "c="),
        (profile.WAIT_MS, "4000"), (profile.BUTTON, "a"),
        (profile.WAIT_MS, "2000"), (profile.TEXT, "k")]


def test_a_key_inside_text_stays_text():
    # only a step that is nothing BUT one {name} is a key press, so
    # "hi{ret}there" round-trips instead of being split into three rows
    steps = profile.parse_macro("hi{ret}there")
    assert [(s.kind, s.value) for s in steps] == [(profile.TEXT, "hi{ret}there")]


def test_macro_round_trips():
    for m in ('@boot;load"*",8,1\\r;@load;run\\r',
              "@3000;{c=};#a;sys 4096\\r",
              "{f1}", "@load", ""):
        assert profile.build_macro(profile.parse_macro(m)) == m


def test_empty_steps_are_dropped_like_the_firmware_does():
    assert profile.build_macro(profile.parse_macro("@load;;run\\r")) \
        == "@load;run\\r"


def test_a_semicolon_in_text_is_escaped_not_a_separator():
    steps = profile.parse_macro("print\\;go\\r")
    assert len(steps) == 1 and steps[0].kind == profile.TEXT


def test_step_labels_read_like_english():
    assert profile.step_label(profile.Step(profile.WAIT_MS, "3000")) \
        == "wait 3 s"
    assert profile.step_label(profile.Step(profile.KEY, "c=")) \
        == "press Commodore key (C=)"
    assert profile.step_label(profile.Step(profile.BUTTON, "a")) \
        == "press Fire / button A"
    assert profile.step_label(profile.Step(profile.WAIT_LOAD)) \
        == "wait for the game to finish loading"


def test_describe_macro_is_one_sentence():
    assert profile.describe_macro("@3000;{c=}") \
        == "wait 3 s, then press Commodore key (C=)"


def test_text_step_helpers_hide_the_backslash_r():
    assert profile.text_body('load"*",8,1\\r') == 'load"*",8,1'
    assert profile.text_has_enter('load"*",8,1\\r')
    assert not profile.text_has_enter("run")
    assert profile.text_step("run", True) == "run\\r"
    assert profile.text_step("run\\r", True) == "run\\r"    # not doubled
    assert profile.text_step("run\\r", False) == "run"


def test_steps_built_by_an_editor_pass_validation():
    steps = [profile.Step(profile.WAIT_LOAD),
             profile.Step(profile.WAIT_MS, "3000"),
             profile.Step(profile.KEY, "c=")]
    errs, warns = profile.check_macro(profile.build_macro(steps))
    assert not errs and not warns


def test_a_button_step_is_valid_but_warns_it_does_nothing_yet():
    errs, warns = profile.check_macro(
        profile.build_macro([profile.Step(profile.BUTTON, "a")]))
    assert not errs and any("not executed" in w for w in warns)


def test_a_text_step_label_does_not_leak_the_escape():
    assert profile.step_label(profile.Step(profile.TEXT, 'load"*",8,1\\r')) \
        == """type 'load"*",8,1' and press Return"""
    assert profile.step_label(profile.Step(profile.TEXT, "\\r")) \
        == "press Return"
