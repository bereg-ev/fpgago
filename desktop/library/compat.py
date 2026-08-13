"""library/compat.py — the shared game-compatibility database.

A text-file database in the git repo, `desktop/library/data/compat.jsonl`,
so users report and update compatibility through normal PRs and the history
IS the git history.  One JSON object per line, append-only, which merges
cleanly when two people report different games at the same time:

    {"id":"#2862-A","machine":"c64","status":"issues","mode":"fastload",
     "date":"2026-07-21","by":"bereg","email":"bereg@example.com",
     "bit":"2607201230.0","real1541":true,
     "notes":"needs full 1541 DOS; use AUTO/1541 drive mode"}

Rules of the file:
  * `id` is an absolute canon ID (see canon.py) and MUST carry its check
    character — a wrong-game report is worse than no report.  `#42-K` rates
    the game as a whole, `#42-K/2` one specific release.
  * `status` is one of works / issues / broken.  `machine` is which core it
    ran on (a 264 title can behave differently on c16 vs plus4).  `mode`
    (fastload / 1541 / auto) and `bit` / `fw` versions are optional context.
  * `real1541` is the hard verdict about the drive: true means no fastload
    path works and the game only runs on the cycle-accurate 1541 emulation
    (the slow, real-clock one).  It is a property of the GAME, not of how
    this particular test happened to be run — `mode` records the latter —
    and it is what the Library's "Real 1541" filter searches on.
  * `by` / `email` are who tested it.  The email is what makes a handful of
    testers reviewable: verdicts can be read back per person, and a
    questionable one has somebody to ask.
  * newest report per (id, machine) wins as the *current* verdict; older
    lines stay as history.  Nothing is ever rewritten.

The narrative companion — failure signatures, debugging recipes, root
causes — stays in retro-arch/COMPATIBILITY.md; `notes` should reference it
for anything longer than a sentence.
"""

from __future__ import annotations

import json
import os
import subprocess
import time
from typing import Optional

from . import canon, profile as profile_mod

STATUSES = ("works", "issues", "broken")
# Every machine a verdict (and a profile) can be recorded for.  Adding a
# core here is what lets its games carry shipped settings.
MACHINES = ("c64", "c16", "plus4", "264")
MODES = ("fastload", "1541", "auto", "dos", "fpga")

_OPTIONAL = ("mode", "bit", "fw", "notes", "sub", "profile", "real1541",
             "email")


def default_path() -> str:
    """The SHARED database — git-tracked, everyone's verdicts."""
    return os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "data", "compat.jsonl")


def online_path() -> str:
    """The shared database as last fetched from the project, cached.

    `compat.jsonl` on disk is only as new as the last `git pull` — and a user
    who unzipped a release never pulls at all.  This is the same file
    downloaded from the project, so "what everyone else found out" can be
    newer than the checkout.
    """
    from . import config
    return os.path.join(config.cache_dir("compat"), "compat.jsonl")


def local_path() -> str:
    """This user's own verdicts, not yet in the shared database.

    Kept in a separate, gitignored file for a plain reason: most people
    testing games do not use git.  Their reports have to land somewhere the
    app can read back immediately and `git pull` can never conflict with —
    and then be *sent* (see share.py), rather than committed.
    """
    return os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "data", "compat-local.jsonl")


def identity_path() -> str:
    """Where this machine remembers who is doing the testing.

    Not in git and not in the compat files: it is one person's name and
    address, typed once in the app, and every report from then on carries it.
    A tester who has never configured git — most of them — otherwise reports
    as `$USER`, which is exactly as reviewable as anonymous.
    """
    from . import config
    return os.path.join(config.games_root(), "reporter.json")


def saved_identity() -> dict:
    """{"by": …, "email": …} as last set, missing keys absent."""
    try:
        with open(identity_path(), encoding="utf-8") as fh:
            got = json.load(fh)
    except (OSError, ValueError):
        return {}
    return {k: str(got[k]).strip() for k in ("by", "email")
            if isinstance(got, dict) and got.get(k)}


def set_identity(by: Optional[str] = None,
                 email: Optional[str] = None) -> dict:
    """Remember who is testing.  Only the fields given are touched; an empty
    string clears one.  Returns the identity as it now stands."""
    cur = saved_identity()
    for key, val in (("by", by), ("email", email)):
        if val is None:
            continue
        val = str(val).strip()
        if val:
            cur[key] = val
        else:
            cur.pop(key, None)
    path = identity_path()
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(cur, fh, ensure_ascii=False, indent=1)
    return cur


_GIT_CFG: dict = {}


def _git_config(key: str) -> str:
    """`git config --get`, asked once per process: append_report calls this
    for every line written, and a subprocess per report is a real cost in a
    bulk import."""
    if key not in _GIT_CFG:
        try:
            _GIT_CFG[key] = subprocess.run(
                ["git", "config", "--get", key], capture_output=True,
                text=True, timeout=5).stdout.strip()
        except Exception:                            # noqa: BLE001
            _GIT_CFG[key] = ""
    return _GIT_CFG[key]


def default_reporter() -> str:
    return (saved_identity().get("by")
            or _git_config("user.name")
            or os.environ.get("USER", "unknown"))


def default_email() -> str:
    """The tester's address, or "" when nobody has said.  What the app puts
    in the review box; $FPGAGO_EMAIL wins so a test rig can set it once."""
    return (os.environ.get("FPGAGO_EMAIL", "").strip()
            or saved_identity().get("email")
            or _git_config("user.email"))


def valid_email(addr: str) -> bool:
    """Deliberately shallow — this is a contact hint, not an auth factor, and
    a strict pattern would reject somebody's perfectly working address."""
    addr = (addr or "").strip()
    if not addr or " " in addr or addr.count("@") != 1:
        return False
    local, _, domain = addr.partition("@")
    return bool(local) and "." in domain and not domain.startswith(".") \
        and not domain.endswith(".")


class CompatError(Exception):
    """A report line is malformed (bad ID / status / machine / JSON)."""


def validate(rep: dict, lineno: Optional[int] = None) -> dict:
    """Check one report dict; returns it normalised.  Raises CompatError."""
    where = f"line {lineno}: " if lineno else ""
    rid = rep.get("id", "")
    try:
        canon_id, sub = canon.parse_id(rid)
    except ValueError as e:
        raise CompatError(f"{where}{e}") from e
    if "-" not in rid.lstrip("#"):
        raise CompatError(
            f"{where}id {rid!r} lacks its check character — write it as "
            f"{canon.format_id(canon_id, sub)}")
    if rep.get("status") not in STATUSES:
        raise CompatError(f"{where}status {rep.get('status')!r} not in "
                          f"{'/'.join(STATUSES)}")
    if rep.get("machine") not in MACHINES:
        raise CompatError(f"{where}machine {rep.get('machine')!r} not in "
                          f"{'/'.join(MACHINES)}")
    if rep.get("mode") is not None and rep["mode"] not in MODES:
        raise CompatError(f"{where}mode {rep.get('mode')!r} not in "
                          f"{'/'.join(MODES)}")
    # A flag, so it has to BE one: "yes"/1/"true" would each read as true in
    # some language and false in another, and this one decides whether a game
    # is listed as playable-only-on-the-real-drive.
    if rep.get("real1541") is not None and not isinstance(rep["real1541"],
                                                          bool):
        raise CompatError(f"{where}real1541 must be true or false, not "
                          f"{rep['real1541']!r}")
    if rep.get("email") is not None and not valid_email(rep["email"]):
        raise CompatError(f"{where}email {rep['email']!r} is not an address")
    if not rep.get("date"):
        raise CompatError(f"{where}missing date (YYYY-MM-DD)")
    # The optional per-game settings profile shipped with this verdict.  Hard
    # errors only (size, syntax) — see profile.py for why unknown keys warn.
    if rep.get("profile") is not None:
        try:
            profile_mod.validate(rep["profile"], "profile")
        except profile_mod.ProfileError as e:
            raise CompatError(f"{where}{e}") from e
    rep["_canon"], rep["_sub"] = canon_id, sub
    return rep


# Where a verdict came from.  YOURS is this user's own testing; ONLINE is
# everyone else's, whether it arrived by git or by download.
SRC_YOURS, SRC_ONLINE = "yours", "online"


def have_synced() -> bool:
    """Whether a downloaded copy of the shared database exists."""
    path = online_path()
    try:
        return os.path.getsize(path) > 0
    except OSError:
        return False


def shared_paths() -> list:
    """The shared database, from every copy this machine actually has.

    The download and the committed file overlap almost entirely — everything
    the server publishes came from that file — so this used to return the
    download ALONE once a sync had happened, to stop the project's history
    being listed twice.  That silently broke the maintainer's own write path:
    `append_report` writes to the committed file, and on a synced machine
    nothing read it back.  A verdict recorded here vanished from `show`,
    `list` and the app until the server had published it and you re-synced,
    which reads as a lost report rather than a slow one.

    So both are read and `_dedup` collapses the overlap.  The committed file
    comes LAST, which is what makes a just-written report win `current()`'s
    date tie-break against the copy that was downloaded before it.
    """
    return ([online_path(), default_path()] if have_synced()
            else [default_path()])


def _dedup(reports: list) -> list:
    """Reports with the overlap between two copies of the same database
    removed, first occurrence kept.  Two lines agreeing on every field a
    person typed *and* on who typed them are the same claim — see
    `_identity`, which `share` already trusts for exactly this."""
    seen, out = set(), []
    for r in reports:
        key = _identity(r) + (r.get("by"),)
        if key in seen:
            continue
        seen.add(key)
        out.append(r)
    return out


def load_tagged(include_online: bool = True):
    """Every report, each tagged `_src` with who it came from.

    The distinction is the point: "it works" from your own board and "it
    works" from the project database are different claims, and when they
    disagree the user is the only one who can say which is right.
    """
    shared = []
    if include_online:
        for path in shared_paths():
            reports, _ = _load_one(path)
            for r in reports:
                r["_src"] = SRC_ONLINE
            shared += reports
    # Only the shared copies are deduped: a local report that has since been
    # published legitimately appears twice, once as yours and once as the
    # project's, and telling those apart is what this function is for.
    out = _dedup(shared)
    reports, _ = _load_one(local_path())
    for r in reports:
        r["_src"] = SRC_YOURS
    return out + reports


def load(path: Optional[str] = None, strict: bool = False,
         include_local: bool = True):
    """Parse the database.  Returns (reports, errors) — errors are per-line
    strings; strict=True raises on the first one instead (CI / verify).

    With no explicit path this reads the shared database AND this user's own
    local reports, local last — so a verdict just recorded in the app is the
    current one everywhere in the app, before it has been shared with anyone.
    """
    if path is not None:
        return _load_one(path, strict)
    reports, errors = [], []
    for shared in shared_paths():
        r, e = _load_one(shared, strict)
        reports += r
        errors += e
    reports = _dedup(reports)
    if include_local:
        r3, e3 = _load_one(local_path(), strict)
        reports += r3
        errors += e3
    return reports, errors


# The shared database used to be fetched straight from raw.githubusercontent,
# because the only other copy was whatever the checkout happened to hold.
# `library/webdb.py` downloads it from fpgago.com now, as one of the files in
# the manifest, and writes it to online_path() — so the merge above is
# unchanged and the GitHub fallback is gone.

def _load_one(path: str, strict: bool = False):
    reports, errors = [], []
    if not os.path.exists(path):
        return reports, errors
    with open(path, encoding="utf-8") as fh:
        for i, line in enumerate(fh, start=1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                rep = validate(json.loads(line), lineno=i)
            except (ValueError, CompatError) as e:
                msg = f"line {i}: {e}" if "line" not in str(e) else str(e)
                if strict:
                    raise CompatError(msg) from e
                errors.append(msg)
                continue
            reports.append(rep)
    return reports, errors


def append_report(*, canon_id: int, sub: Optional[int], machine: str,
                  status: str, mode: Optional[str] = None,
                  bit: Optional[str] = None, fw: Optional[str] = None,
                  notes: Optional[str] = None, by: Optional[str] = None,
                  date: Optional[str] = None, profile: Optional[str] = None,
                  real1541: Optional[bool] = None,
                  email: Optional[str] = None,
                  path: Optional[str] = None, local: bool = False) -> dict:
    """Validate + append one report line.  Returns the written dict.
    `local=True` files it under this user's own reports (local_path()), where
    the app can offer to share it — see share.py.

    `real1541=False` is written out, unlike the other optional fields: `None`
    means "this report says nothing about the drive" and False means "I
    checked, and fastload is fine" — which is the only way a flag somebody
    set by mistake can be taken back.  See current_real1541().
    """
    if path is None and local:
        path = local_path()
    rep = {"id": canon.format_id(canon_id, sub), "machine": machine,
           "status": status,
           "date": date or time.strftime("%Y-%m-%d"),
           "by": by or default_reporter()}
    email = (email if email is not None else default_email()) or ""
    if email.strip():
        rep["email"] = email.strip()
    if real1541 is not None:
        rep["real1541"] = bool(real1541)
    for key, val in (("mode", mode), ("bit", bit), ("fw", fw),
                     ("notes", notes), ("profile", profile)):
        if val:
            rep[key] = val
    validate(dict(rep))
    path = path or default_path()
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rep, ensure_ascii=False,
                            separators=(",", ":")) + "\n")
    return rep


def unshared() -> list:
    """This user's reports that have not been sent anywhere yet."""
    reports, _ = _load_one(local_path())
    return [r for r in reports if not r.get("shared")]


def _identity(rep: dict) -> tuple:
    """What makes two report lines the same report, for matching a server's
    answer back to the file it came from.  Not an ID — reports have none —
    but every field a user typed, which is specific enough that two lines
    that match really are the same claim."""
    return tuple(rep.get(k) for k in
                 ("id", "machine", "status", "date", "mode", "bit", "fw",
                  "notes", "profile"))


def mark_shared(when: Optional[str] = None, only=None) -> int:
    """Stamp local reports as shared; returns how many.

    Rewrites the local file, which the shared database would never allow —
    but this one is a single user's scratch file, not a thing two people
    merge, so an in-place stamp is the honest way to stop re-offering the
    same reports forever.

    `only` limits the stamp to the given reports.  A server that accepted
    nine of ten submissions must not cause the tenth to be marked as sent:
    it is the one the user most needs offered again.
    """
    path = local_path()
    if not os.path.exists(path):
        return 0
    when = when or time.strftime("%Y-%m-%d")
    wanted = {_identity(r) for r in only} if only is not None else None
    out, n = [], 0
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                out.append(line)
                continue
            try:
                rep = json.loads(line)
            except ValueError:
                out.append(line)
                continue
            if not rep.get("shared") and (wanted is None
                                          or _identity(rep) in wanted):
                rep["shared"] = when
                n += 1
            out.append(json.dumps(rep, ensure_ascii=False,
                                  separators=(",", ":")))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out) + ("\n" if out else ""))
    return n


def report_lines(reports) -> str:
    """The reports as the JSONL a maintainer can paste straight into
    compat.jsonl — internal `_`-keys and our `shared` stamp removed."""
    out = []
    for r in reports:
        clean = {k: v for k, v in r.items()
                 if not k.startswith("_") and k != "shared"}
        out.append(json.dumps(clean, ensure_ascii=False,
                              separators=(",", ":")))
    return "\n".join(out)


def current(reports, canon_id: int, sub: Optional[int] = None):
    """Current verdict(s) for a game: {machine: report}.  The newest report
    per machine wins (date, then file order).  With sub=None, game-level
    and every variant's reports are considered (variant-specific newest
    still wins for its machine); with a sub, only that variant + game-level
    reports apply."""
    best: dict = {}
    for i, r in enumerate(reports):
        if r["_canon"] != canon_id:
            continue
        if sub is not None and r["_sub"] not in (None, sub):
            continue
        key = r["machine"]
        cur = best.get(key)
        if cur is None or (r["date"], i) >= (cur[0]["date"], cur[1]):
            best[key] = (r, i)
    return {m: r for m, (r, _) in best.items()}


def _latest_field(reports, canon_id: int, machine: str, key: str,
                  sub: Optional[int] = None):
    """The value of `key` from the newest report for (game, machine) that
    carries it at all, or None.

    Reports that leave the field out are skipped rather than counted as
    "cleared": a field like `profile` or `real1541` is a separate finding
    from the verdict, and "I retested it and it still works" must not
    silently drop the settings — or the drive requirement — that the game
    was found to need.  Writing the field explicitly is how it is changed.
    """
    best = None
    for i, r in enumerate(reports):
        if r["_canon"] != canon_id or r["machine"] != machine:
            continue
        if sub is not None and r["_sub"] not in (None, sub):
            continue
        if r.get(key) is None:
            continue
        if best is None or (r["date"], i) >= (best[0], best[1]):
            best = (r["date"], i, r[key])
    return best[2] if best else None


def current_profile(reports, canon_id: int, machine: str,
                    sub: Optional[int] = None) -> Optional[str]:
    """The profile from the newest verdict for (game, machine) that carries
    one, or None.  See _latest_field for why a later verdict without one does
    not erase it."""
    return _latest_field(reports, canon_id, machine, "profile", sub)


def current_real1541(reports, canon_id: int, machine: str,
                     sub: Optional[int] = None) -> Optional[bool]:
    """Whether this game needs the real 1541 on this machine: True, False
    (somebody checked and it does not), or None (nobody has said)."""
    return _latest_field(reports, canon_id, machine, "real1541", sub)


def real1541_ids(reports) -> set:
    """Every canon ID currently flagged as needing the real 1541, on any
    machine — what the Library's search filter runs on.

    Per (game, machine), the newest report that mentions the drive decides;
    a later `false` on the machine that was flagged clears it.  A game
    flagged on the c64 and cleared on the plus4 stays in the set: the flag
    describes a real limitation somewhere, and hiding it because another
    core is fine is the wrong way round.
    """
    best: dict = {}
    for i, r in enumerate(reports):
        if r.get("real1541") is None:
            continue
        key = (r["_canon"], r["machine"])
        cur = best.get(key)
        if cur is None or (r["date"], i) >= (cur[0], cur[1]):
            best[key] = (r["date"], i, bool(r["real1541"]))
    return {cid for (cid, _m), (_d, _i, flag) in best.items() if flag}


def status_line(rep: dict) -> str:
    mark = {"works": "OK", "issues": "ISSUES", "broken": "BROKEN"}[rep["status"]]
    extra = "".join(f" {k}={rep[k]}" for k in ("mode", "bit") if rep.get(k))
    if rep.get("real1541"):
        extra += " REAL-1541"
    if rep.get("profile") is not None:
        extra += "  [" + profile_mod.describe(rep["profile"]) + "]"
    note = f"  — {rep['notes']}" if rep.get("notes") else ""
    who = rep.get("by", "?")
    if rep.get("email"):
        who += f" <{rep['email']}>"
    return f"{rep['machine']:6} {mark:7}{extra}  ({rep['date']} {who}){note}"
