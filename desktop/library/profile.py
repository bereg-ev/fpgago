"""library/profile.py — per-game settings profiles, desktop side.

The board keeps one profile per game in its KV store under `g.<filename>`:
newline-separated `key=value` text, at most 255 bytes.  The format, the
setting tokens and the start-up macro grammar are defined by the firmware —
the board firmware's per-game profile store — and this module is
the desktop half: parse, validate, and build one.

Where profiles come from: `desktop/library/data/compat.jsonl`.  A compat
report already records the verdict *and the mode a game needed*
(`"mode":"auto"`), which is a per-game setting written down by hand and then
applied by hand.  The optional `"profile"` field on a report closes that loop
— `library.cli upload` pushes it to the board with the game.

Validation is deliberately asymmetric:

  * HARD errors for anything objective — over 255 bytes, a line with no `=`,
    an unclosed `{`, a malformed `@wait`.  These are rejected by
    `compat verify`, i.e. in CI.
  * WARNINGS for anything that depends on a firmware table this file only
    mirrors: an unknown setting key, an unknown `{keyname}`.  A newer
    firmware may well know them, and a hard failure here would mean the
    database could not carry a profile the board understands.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Optional

MAX = 255                       # KV_VAL_MAX, the whole blob
KEY_PREFIX = "g."               # KV key = prefix + the flash filename

# Setting tokens — mirror gpDriveTok / gpSpeedTok / gpBtnTok in
# the board firmware.  The INDEX is the firmware's own enum value.
DRIVE = ("fastload", "1541", "auto", "dos", "fpga")
SPEED = ("std", "t15", "t2")
BTN = ("text", "joy1", "joy2", "joyboth")

# Keys the firmware acts on, and what a value may be.  `None` = free text.
SETTINGS = {
    "drive": DRIVE,
    "speed": SPEED,
    "btn": BTN,
    "type": None,               # the start-up macro
}

# Keys that are parsed by the firmware but deliberately never applied — see
# game_profile.h.  Accepted here so a database entry is not rejected for
# carrying one, but flagged, since setting them does nothing today.
INERT = ("vol", "bright")

# Named keys a macro may type, mirroring `as_keys[]` in bios_ui.c.  Only used
# for warnings, so drift costs a false warning, never a false rejection.
KEYNAMES = (
    "ret", "return", "stop", "run", "rs", "c=", "ctrl", "home", "clr",
    "del", "inst", "space", "up", "down", "left", "right", "pound",
    "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8",
)
BUTTONS = ("up", "down", "left", "right", "a", "b", "c", "d")

# What to call those in a UI.  The NAME is wire format (it is stored in a
# profile on the board); the label is ours.  `return` is left out because it
# is an alias of `ret`, and offering both would be a coin toss with no
# difference.
KEY_LABELS = (
    ("ret", "Return"), ("space", "Space"), ("stop", "RUN/STOP"),
    ("run", "SHIFT+RUN/STOP (load+run)"), ("rs", "RESTORE"),
    ("c=", "Commodore key (C=)"), ("ctrl", "CTRL"),
    ("up", "Cursor up"), ("down", "Cursor down"),
    ("left", "Cursor left"), ("right", "Cursor right"),
    ("home", "HOME"), ("clr", "CLR (shift+home)"),
    ("del", "DEL"), ("inst", "INST (shift+del)"), ("pound", "£"),
    ("f1", "F1"), ("f2", "F2"), ("f3", "F3"), ("f4", "F4"),
    ("f5", "F5"), ("f6", "F6"), ("f7", "F7"), ("f8", "F8"),
)
BUTTON_LABELS = (
    ("a", "Fire / button A"), ("b", "Button B"), ("c", "Button C"),
    ("d", "Button D"), ("up", "Joystick up"), ("down", "Joystick down"),
    ("left", "Joystick left"), ("right", "Joystick right"),
)


class ProfileError(Exception):
    """A profile blob is malformed."""


def kv_key(flash_name: str) -> str:
    """The board's KV key for a game's profile."""
    return KEY_PREFIX + flash_name


def parse(blob: str) -> dict:
    """Blob -> {key: value}, with the firmware's rules: \\n or \\r ends a
    line, a leading '#' is a comment, whitespace around key and value is
    trimmed, and the FIRST occurrence of a key wins."""
    out: dict = {}
    for line in re.split(r"\r\n|\r|\n", blob or ""):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip().lower()
        if key and key not in out:
            out[key] = val.strip()
    return out


def build(**settings) -> str:
    """Build a blob from keyword settings, skipping None.  Key order is
    stable so a rebuilt profile diffs cleanly in git."""
    order = ("drive", "speed", "btn", "type")
    parts = []
    for key in order:
        val = settings.get(key)
        if val is not None:
            parts.append(f"{key}={val}")
    for key, val in sorted(settings.items()):
        if key not in order and val is not None:
            parts.append(f"{key}={val}")
    return "\n".join(parts)


def update(blob: str, changes: dict) -> str:
    """Apply {key: value-or-None} to a blob — the desktop twin of gpSet() in
    game_profile.c.  A None value removes the key; every OTHER key survives,
    including ones this version does not understand.  That is what lets an
    editor round-trip a profile written by a newer firmware without quietly
    deleting half of it."""
    settings = parse(blob)
    for key, val in changes.items():
        if val is None:
            settings.pop(key, None)
        else:
            settings[key] = val
    return build(**settings)


# ── the start-up macro ──────────────────────────────────────────────────────

_ESCAPES = "rnt\\;{@#"


def _split_steps(macro: str):
    """Split on unescaped ';'."""
    steps, cur, i = [], [], 0
    while i < len(macro):
        c = macro[i]
        if c == "\\" and i + 1 < len(macro):
            cur.append(macro[i:i + 2])
            i += 2
            continue
        if c == ";":
            steps.append("".join(cur))
            cur = []
        else:
            cur.append(c)
        i += 1
    steps.append("".join(cur))
    return steps


def check_macro(macro: str):
    """Returns (errors, warnings) for one `type=` value."""
    errors, warnings = [], []
    for raw in _split_steps(macro):
        step = raw.strip()
        if not step:
            continue                            # ";;" is skipped, not an error

        if step.startswith("@"):
            tok = step[1:].lower()
            if tok in ("boot", "load"):
                continue
            if not tok.isdigit():
                errors.append(f"@{tok or ''}: not a wait — use @boot, @load "
                              f"or @<milliseconds>")
            elif int(tok) > 65535:
                errors.append(f"@{tok}: wait is longer than 65535 ms")
            continue

        if step.startswith("#"):
            name = step[1:].lower()
            if name not in BUTTONS:
                errors.append(f"#{name}: not a button "
                              f"({'/'.join(BUTTONS)})")
            else:
                warnings.append(f"#{name}: button steps are parsed but not "
                                "executed by the firmware yet")
            continue

        # a text step: check the braces and the names inside it
        i = 0
        while i < len(step):
            c = step[i]
            if c == "\\":
                if i + 1 >= len(step):
                    errors.append("trailing '\\' with nothing to escape")
                elif step[i + 1] not in _ESCAPES:
                    warnings.append(f"\\{step[i + 1]}: not an escape, types "
                                    f"'{step[i + 1]}' literally")
                i += 2
                continue
            if c == "{":
                end = step.find("}", i)
                if end < 0:
                    errors.append(f"unclosed '{{' in {step!r}")
                    break
                name = step[i + 1:end].lower()
                if name not in KEYNAMES:
                    warnings.append(f"{{{name}}}: not a key this firmware "
                                    "knows — it will be skipped, not typed")
                i = end + 1
                continue
            i += 1
    return errors, warnings


# ── the macro as a list of steps (what an editor edits) ─────────────────────
#
# The macro is a string because that is what fits in 255 bytes of flash and
# what gpMacroNext() walks.  Nobody wants to *write* one, though, so this is
# the same thing as a list of actions — "wait 3 s, press C=, wait 4 s, fire"
# — that a table can show one per row.  The grammar stays here, in the module
# the firmware's format lives in; the GUI is just a table over these.

WAIT_BOOT, WAIT_LOAD, WAIT_MS = "boot", "load", "ms"
TEXT, KEY, BUTTON = "text", "key", "button"

_KEY_ONLY = re.compile(r"^\{([^{}]*)\}$")


@dataclass
class Step:
    """One macro step.  `kind` is one of the six constants above; `value` is
    the milliseconds (WAIT_MS), the text (TEXT), the key name (KEY) or the
    button name (BUTTON), and is unused for the two named waits."""
    kind: str
    value: str = ""


def parse_macro(macro: str) -> list[Step]:
    """Macro string -> steps.  Empty steps are dropped, exactly as the
    firmware's walker skips them."""
    out = []
    for raw in _split_steps(macro or ""):
        step = raw.strip()
        if not step:
            continue
        if step.startswith("@"):
            tok = step[1:].lower()
            if tok == "boot":
                out.append(Step(WAIT_BOOT))
            elif tok == "load":
                out.append(Step(WAIT_LOAD))
            else:
                out.append(Step(WAIT_MS, tok))
        elif step.startswith("#"):
            out.append(Step(BUTTON, step[1:].lower()))
        else:
            m = _KEY_ONLY.match(step)
            # a step that is nothing but one {name} is a key press; anything
            # else — including "hi{ret}there" — stays text, so it round-trips
            out.append(Step(KEY, m.group(1).lower()) if m
                       else Step(TEXT, step))
    return out


def build_macro(steps) -> str:
    """Steps -> macro string."""
    parts = []
    for s in steps:
        if s.kind == WAIT_BOOT:
            parts.append("@boot")
        elif s.kind == WAIT_LOAD:
            parts.append("@load")
        elif s.kind == WAIT_MS:
            parts.append(f"@{s.value}")
        elif s.kind == KEY:
            parts.append("{%s}" % s.value)
        elif s.kind == BUTTON:
            parts.append(f"#{s.value}")
        else:
            parts.append(s.value)
    return ";".join(parts)


def step_label(step: Step) -> str:
    """One human line for a step, for a list or a summary."""
    if step.kind == WAIT_BOOT:
        return "wait for the machine to start up"
    if step.kind == WAIT_LOAD:
        return "wait for the game to finish loading"
    if step.kind == WAIT_MS:
        try:
            return f"wait {int(step.value) / 1000:g} s"
        except ValueError:
            return f"wait {step.value}?"
    if step.kind == KEY:
        return "press " + dict(KEY_LABELS).get(step.value, step.value)
    if step.kind == BUTTON:
        return "press " + dict(BUTTON_LABELS).get(step.value, step.value)
    body = text_body(step.value)
    return (f"type {body!r}" + (" and press Return" if text_has_enter(step.value)
                                else "")) if body else "press Return"


def describe_macro(macro: str) -> str:
    """The whole macro as one readable sentence."""
    steps = parse_macro(macro)
    return ", then ".join(step_label(s) for s in steps) or "(nothing)"


# The trailing Return is the single most common thing a text step needs, and
# `\r` in a text box is not something a user should have to know about.
def text_body(value: str) -> str:
    """A TEXT step's text without its trailing Return."""
    return value[:-2] if value.endswith("\\r") else value


def text_has_enter(value: str) -> bool:
    return value.endswith("\\r")


def text_step(body: str, enter: bool) -> str:
    """Build a TEXT step's value from a plain string + "press Return"."""
    return text_body(body) + ("\\r" if enter else "")


# ── whole-profile validation ────────────────────────────────────────────────

def check(blob: str):
    """Returns (errors, warnings) for a whole profile blob."""
    errors, warnings = [], []

    if blob is None:
        return ["profile is null"], []
    n = len(blob.encode("utf-8"))
    if n > MAX:
        errors.append(f"profile is {n} bytes, the board stores at most {MAX}")
    if blob != blob.strip():
        warnings.append("leading/trailing whitespace is trimmed by the board")

    seen = set()
    for line in re.split(r"\r\n|\r|\n", blob):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in stripped:
            errors.append(f"{stripped!r}: not a key=value line")
            continue
        key = stripped.partition("=")[0].strip().lower()
        if not key:
            errors.append(f"{stripped!r}: empty key")
        elif key in seen:
            warnings.append(f"{key}: duplicate line, the board uses the first")
        seen.add(key)

    settings = parse(blob)
    for key, val in settings.items():
        if key in INERT:
            warnings.append(f"{key}: parsed by the board but never applied "
                            "(volume and brightness are user settings)")
            continue
        if key not in SETTINGS:
            warnings.append(f"{key}: not a setting this firmware applies")
            continue
        allowed = SETTINGS[key]
        if allowed is None:
            continue
        if val.lower() not in allowed:
            errors.append(f"{key}={val}: not one of {'/'.join(allowed)}")

    if "type" in settings:
        e, w = check_macro(settings["type"])
        errors += [f"type: {m}" for m in e]
        warnings += [f"type: {m}" for m in w]

    return errors, warnings


def validate(blob: str, where: str = "") -> str:
    """Raise ProfileError on any hard error; returns the blob."""
    errors, _ = check(blob)
    if errors:
        prefix = f"{where}: " if where else ""
        raise ProfileError(prefix + "; ".join(errors))
    return blob


def describe(blob: str) -> str:
    """One human line summarising a profile, for CLI listings."""
    s = parse(blob)
    bits = []
    for key in ("drive", "speed", "btn"):
        if key in s:
            bits.append(f"{key}={s[key]}")
    if "type" in s:
        bits.append("autostart=off" if not s["type"] else "macro")
    for key in sorted(s):
        if key not in ("drive", "speed", "btn", "type"):
            bits.append(key)
    return " ".join(bits) or "(empty)"
