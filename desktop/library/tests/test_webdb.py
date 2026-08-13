"""Syncing the game database from fpgago.com.

The tests run a real HTTP server on a loopback port rather than mocking
`fetch`, because most of what can go wrong here is in the wire format and the
change detection, not in the Python: a manifest that names a file that is not
there, a sha1 that moved mid-publish, a re-import that duplicates every game.
"""

from __future__ import annotations

import hashlib
import json
import os
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

import pytest

from library import canon, compat, config, fetch, webdb
from library.db import Catalog


# ── a published tree, served over loopback ─────────────────────────────────

def jsonl(obj) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def write_catalog(path: str, platform: str, entries: list[dict]):
    """Write a platform file exactly as the server publishes one: v2 header,
    one game per line, integrity footer over every preceding byte."""
    lines = [jsonl({"canon": "fpgago-games", "v": 2, "platform": platform})]
    nvar = 0
    for e in entries:
        e = dict(e, chk=canon.check_char(e["id"]))
        nvar += len(e.get("variants", []))
        lines.append(jsonl(e))
    body = ("\n".join(lines) + "\n").encode("utf-8")
    footer = {"games": len(entries), "variants": nvar,
              "sha1": hashlib.sha1(body).hexdigest()}
    with open(path, "wb") as fh:
        fh.write(body)
        fh.write((jsonl(footer) + "\n").encode("utf-8"))


WOW = {
    "id": 4193, "title": "Wizard of Wor", "year": 1983,
    "publisher": "Commodore",
    "variants": [
        {"n": 1, "platform": "c64", "source": "archive",
         "ref": "wow_c64_bandit", "group": "Bandit", "fmt": "d64",
         "url": "https://archive.org/download/wow/wow.d64",
         "filename": "wow.d64", "size": 174848, "sha1": "a" * 40,
         "crc32": "46463899"},
        {"n": 5, "platform": "c64", "source": "archive", "ref": "wow_c64_atg",
         "group": "ATG"},
    ],
}
WIZARD = {
    "id": 10, "title": "Wizard",
    "variants": [
        # A husk: this ID still resolves, but the release lives at #4193-U/5.
        {"n": 1, "platform": "c64", "source": "archive", "ref": "wow_c64_atg",
         "group": "ATG", "moved": "#4193-U/5"},
    ],
}


class Server:
    """A published tree on a loopback port, counting what gets fetched."""

    def __init__(self, root: str):
        self.root = root
        self.hits: list[str] = []
        outer = self

        class Handler(SimpleHTTPRequestHandler):
            def translate_path(self, path):
                return os.path.join(outer.root, path.lstrip("/").split("?")[0])

            def do_GET(self):
                outer.hits.append(self.path)
                super().do_GET()

            def log_message(self, *a):
                pass

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()


def publish(root: str, files: dict[str, str]) -> dict:
    """Write the given {name: body} plus a manifest describing them."""
    entries = []
    for name, body in sorted(files.items()):
        path = os.path.join(root, name)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(body)
        raw = body.encode("utf-8")
        entries.append({"name": name, "url": "/" + name, "serial": 1,
                        "sha1": hashlib.sha1(raw).hexdigest(),
                        "size": len(raw)})
    manifest = {"manifest": "fpgago-gamedb", "v": 1,
                "generated": "2026-08-05T12:00:00Z", "files": entries}
    with open(os.path.join(root, "api-manifest.json"), "w") as fh:
        json.dump(manifest, fh)
    return manifest


@pytest.fixture
def site(tmp_path, monkeypatch):
    """A running server with a two-platform catalog, and a client pointed at
    it with its own empty library."""
    root = tmp_path / "site"
    root.mkdir()
    games = tmp_path / "games"
    games.mkdir()
    monkeypatch.setenv("FPGAGO_GAMES", str(games))
    # The politeness delay is for other people's servers; against a loopback
    # fixture it is a minute of sleeping per run.
    monkeypatch.setattr(fetch, "MIN_INTERVAL", 0.0)

    c64 = tmp_path / "c64.jsonl"
    write_catalog(str(c64), "c64", [WIZARD, WOW])
    plus4 = tmp_path / "plus4.jsonl"
    write_catalog(str(plus4), "plus4", [
        {"id": 77, "title": "Terra Nova",
         "variants": [{"n": 1, "platform": "plus4", "source": "plus4world",
                       "ref": "tn"}]}])
    publish(str(root), {
        "c64.jsonl": c64.read_text(),
        "plus4.jsonl": plus4.read_text(),
        "compat.jsonl": jsonl({"id": "#4193-U", "machine": "c64",
                               "status": "works", "date": "2026-07-22",
                               "by": "bereg"}) + "\n",
        "screenshots.jsonl": "",
    })

    server = Server(str(root))
    monkeypatch.setenv("FPGAGO_WEB_URL", server.url)
    # The manifest lives at /api/v1/manifest on the real server; the fixture
    # serves the same bytes from a plain file.
    monkeypatch.setattr(webdb, "MANIFEST_PATH", "/api-manifest.json")
    yield server
    server.stop()


def catalog() -> Catalog:
    return Catalog(config.db_path())


# ── tests ──────────────────────────────────────────────────────────────────

def test_first_sync_imports_everything(site):
    res = webdb.sync()
    assert res["errors"] == []
    assert set(res["changed"]) == {"c64.jsonl", "plus4.jsonl", "compat.jsonl",
                                   "screenshots.jsonl"}
    cat = catalog()
    try:
        assert cat.stats()["games"] == 3
        wow = cat.game_by_canon(4193)
        assert wow["title"] == "Wizard of Wor"
        assert wow["year"] == 1983
        v = cat.variant_by_canon(4193, 1)
        assert v["group_name"] == "Bandit"
        assert v["platform"] == "c64"
    finally:
        cat.close()


def test_resync_downloads_nothing(site):
    webdb.sync()
    site.hits.clear()
    res = webdb.sync()
    assert res["changed"] == []
    assert len(res["unchanged"]) == 4
    # The manifest is the only thing that goes over the wire.
    assert [h for h in site.hits if h.endswith(".jsonl")] == []


def test_only_the_changed_file_is_downloaded(site):
    webdb.sync()
    # Publish a new verdict; the catalogs are untouched.
    publish(site.root, {
        "c64.jsonl": open(os.path.join(site.root, "c64.jsonl")).read(),
        "plus4.jsonl": open(os.path.join(site.root, "plus4.jsonl")).read(),
        "compat.jsonl": (jsonl({"id": "#4193-U", "machine": "c64",
                                "status": "works", "date": "2026-07-22",
                                "by": "bereg"}) + "\n"
                         + jsonl({"id": "#77-Q", "machine": "plus4",
                                  "status": "issues", "date": "2026-08-05",
                                  "by": "someone"}) + "\n"),
        "screenshots.jsonl": "",
    })
    site.hits.clear()
    res = webdb.sync()
    assert res["changed"] == ["compat.jsonl"]
    assert [h for h in site.hits if h.endswith(".jsonl")] == ["/compat.jsonl"]


def test_sync_is_idempotent(site):
    webdb.sync()
    webdb.sync()
    webdb.sync()
    cat = catalog()
    try:
        # Three syncs, still three games and four releases — no duplicates.
        assert cat.stats()["games"] == 3
        assert cat.stats()["variants"] == 3
    finally:
        cat.close()


def test_the_multiplayer_flag_syncs_both_ways(site):
    """Ticked on the server it lands here; unticked it clears again.  The
    file format carries "multiplayer" only when set, so its absence has to
    mean off — a COALESCE-style merge would make the flag impossible to ever
    clear from the server."""
    def republish(wow_entry):
        c64_path = os.path.join(site.root, "c64.jsonl")
        write_catalog(c64_path, "c64", [WIZARD, wow_entry])
        publish(site.root, {
            name: open(os.path.join(site.root, name)).read()
            for name in ("c64.jsonl", "plus4.jsonl", "compat.jsonl",
                         "screenshots.jsonl")})

    def flag():
        cat = catalog()
        try:
            return cat.game_by_canon(4193)["multiplayer"]
        finally:
            cat.close()

    webdb.sync()
    assert flag() == 0
    republish(dict(WOW, multiplayer=True))
    webdb.sync()
    assert flag() == 1
    republish(WOW)
    webdb.sync()
    assert flag() == 0


def test_moved_release_becomes_a_redirect_not_a_row(site):
    """The husk shares (source, source_ref) with the release it points at, so
    it cannot be a variant row — the catalog holds those unique."""
    webdb.sync()
    cat = catalog()
    try:
        rows = cat.db.execute(
            "SELECT id, game_id FROM variant WHERE source_ref='wow_c64_atg'"
        ).fetchall()
        assert len(rows) == 1
        # ...and it belongs to the game the server says it does.
        live = cat.variant_by_canon(4193, 5)
        assert live is not None
        assert webdb.resolve_moved(cat, 10, 1) == (4193, 5)
        assert webdb.resolve_moved(cat, 4193, 1) is None
    finally:
        cat.close()


def test_published_hashes_land_as_files(site):
    """The hashes are what let a download be verified against the ID it was
    assigned to."""
    webdb.sync()
    cat = catalog()
    try:
        v = cat.variant_by_canon(4193, 1)
        files = cat.files_for_variant(v["id"])
        assert len(files) == 1
        assert files[0]["sha1"] == "a" * 40
        assert files[0]["size"] == 174848
        assert files[0]["path"] is None       # described, not downloaded
    finally:
        cat.close()


def test_server_correction_refiles_an_existing_local_row(site):
    """A row a local search filed under the wrong game must be fixed by the
    sync, not left alone — that is the whole point of the server owning the
    corrections now."""
    cat = catalog()
    try:
        from library.db import GameRow, VariantRow
        gid = cat.upsert_game(GameRow("Wizard of Wor"))
        cat.upsert_variant(gid, VariantRow(
            platform="c64", source="archive", source_ref="wow_c64_atg",
            group_name="wrong"))
        cat.commit()
    finally:
        cat.close()

    webdb.sync()

    cat = catalog()
    try:
        rows = cat.db.execute(
            "SELECT * FROM variant WHERE source_ref='wow_c64_atg'").fetchall()
        assert len(rows) == 1
        assert rows[0]["group_name"] == "ATG"       # server value won
        assert rows[0]["canon_sub"] == 5
    finally:
        cat.close()


def test_compat_lands_where_the_merge_looks_for_it(site):
    webdb.sync()
    reports = compat.load_tagged()
    online = [r for r in reports if r["_src"] == compat.SRC_ONLINE]
    assert any(r["_canon"] == 4193 and r["status"] == "works" for r in online)


def test_sha1_mismatch_imports_nothing(site):
    """A file whose bytes do not match the manifest is refused — the catalog
    must never be built from something nobody vouched for."""
    body = open(os.path.join(site.root, "c64.jsonl")).read()
    manifest = json.load(open(os.path.join(site.root, "api-manifest.json")))
    for f in manifest["files"]:
        if f["name"] == "c64.jsonl":
            f["sha1"] = "b" * 40
    json.dump(manifest, open(os.path.join(site.root, "api-manifest.json"), "w"))

    res = webdb.sync()
    assert any("sha1 mismatch" in e for e in res["errors"])
    assert "c64.jsonl" not in res["changed"]
    cat = catalog()
    try:
        assert cat.game_by_canon(4193) is None      # nothing imported
        assert cat.game_by_canon(77) is not None    # the good file still did
    finally:
        cat.close()
    assert body                                     # untouched on the server


def test_truncated_catalog_is_refused(site):
    """`canon.load_file`'s integrity footer is the guard; this pins that the
    sync actually relies on it."""
    path = os.path.join(site.root, "c64.jsonl")
    lines = open(path).read().splitlines(keepends=True)
    truncated = "".join(lines[:-2]) + lines[-1]      # drop a game, keep footer
    publish(site.root, {
        "c64.jsonl": truncated,
        "plus4.jsonl": open(os.path.join(site.root, "plus4.jsonl")).read(),
        "compat.jsonl": open(os.path.join(site.root, "compat.jsonl")).read(),
        "screenshots.jsonl": "",
    })
    res = webdb.sync()
    assert any("c64.jsonl" in e for e in res["errors"])
    cat = catalog()
    try:
        assert cat.game_by_canon(4193) is None
    finally:
        cat.close()


def test_unreachable_server_raises_cleanly(tmp_path, monkeypatch):
    monkeypatch.setenv("FPGAGO_GAMES", str(tmp_path / "games"))
    monkeypatch.setenv("FPGAGO_WEB_URL", "http://127.0.0.1:9")
    with pytest.raises(webdb.WebDBError):
        webdb.sync()


def _http_error(status, payload):
    import io
    import urllib.error
    return urllib.error.HTTPError(
        "http://x/api/v1/manifest", status, "Service Unavailable", {},
        io.BytesIO(json.dumps(payload).encode()))


def test_an_unpublished_server_says_what_to_do():
    """A server that is up but has published nothing answers 503 with a
    perfectly good explanation.  Reporting that as "cannot reach" sends
    people to look at their wifi (it did — 2026-08-05)."""
    msg = webdb._http_reason(
        _http_error(503, {"error": "nothing has been published yet",
                          "code": "not_published"}),
        "http://x/api/v1/manifest")
    assert "gamedb_publish" in msg
    assert "cannot reach" not in msg


def test_any_other_error_still_quotes_the_server():
    msg = webdb._http_reason(
        _http_error(403, {"error": "go away", "code": "banned"}),
        "http://x/api/v1/manifest")
    assert "go away" in msg and "banned" in msg


def test_platform_filter(site):
    res = webdb.sync(platforms=["plus4"])
    assert "plus4.jsonl" in res["changed"]
    assert "c64.jsonl" not in res["changed"]
    cat = catalog()
    try:
        assert cat.game_by_canon(77) is not None
        assert cat.game_by_canon(4193) is None
    finally:
        cat.close()


def test_status_reports_the_last_sync(site):
    assert webdb.status()["synced"] is False
    webdb.sync()
    st = webdb.status()
    assert st["synced"] is True
    assert st["generated"] == "2026-08-05T12:00:00Z"
    assert "c64.jsonl" in st["files"]


def test_switching_servers_reimports(site, tmp_path, monkeypatch):
    """A different server may have a different ID space, so every remembered
    sha1 has to be dropped rather than trusted."""
    webdb.sync()
    cat = catalog()
    try:
        assert cat.meta_get(webdb.META_BASE) == site.url
        cat.meta_set(webdb.META_BASE, "https://elsewhere.example")
        cat.commit()
    finally:
        cat.close()

    res = webdb.sync()
    assert set(res["changed"]) == {"c64.jsonl", "plus4.jsonl", "compat.jsonl",
                                   "screenshots.jsonl"}


# ── the game's picture vs one release's crack intro ────────────────────────
# Every release under an ID is the same game, so ONE picture stands for all of
# them and is what the browser shows going down the list.  A crack intro is
# the opposite: it belongs to one release and differs between releases, so it
# is cached under its own name and never counts as the game's picture.

def _shots(site, *recs) -> str:
    """Publish a screenshot index, with an image behind every line."""
    os.makedirs(os.path.join(site.root, "shots"), exist_ok=True)
    body = ""
    for rec in recs:
        with open(os.path.join(site.root, rec["url"].lstrip("/")), "wb") as fh:
            fh.write(rec.pop("_blob"))
        body += jsonl(rec) + "\n"
    return body


GAME_SHOT = {"id": 4193, "url": "/shots/4193.png", "w": 320, "h": 200,
             "size": 8, "date": "2026-08-07", "_blob": b"gamepic!"}
INTRO_SHOT = {"id": 4193, "sub": 5, "url": "/shots/4193.5.png", "w": 320,
              "h": 200, "size": 9, "date": "2026-08-07", "_blob": b"cracktro"}


def _sync_with_shots(site, *recs):
    files = {name: open(os.path.join(site.root, name)).read()
             for name in ("c64.jsonl", "plus4.jsonl", "compat.jsonl")}
    files["screenshots.jsonl"] = _shots(site, *[dict(r) for r in recs])
    publish(site.root, files)
    return webdb.sync()


def test_a_picture_and_an_intro_are_cached_apart(site):
    _sync_with_shots(site, GAME_SHOT, INTRO_SHOT)
    game = webdb.shot_path(4193)
    intro = webdb.shot_path(4193, 5)
    assert game != intro
    assert open(game, "rb").read() == b"gamepic!"
    assert open(intro, "rb").read() == b"cracktro"


def test_an_intro_is_not_the_games_picture(site):
    """A game whose only picture is somebody's cracktro still needs a picture
    of the game, so the "has one" filter must not count intros."""
    _sync_with_shots(site, INTRO_SHOT)
    assert webdb.shot_ids() == set()
    assert webdb.shot_path(4193) is None
    assert webdb.intro_subs(4193) == {5}


def test_the_game_picture_alone_leaves_no_intros(site):
    _sync_with_shots(site, GAME_SHOT)
    assert webdb.shot_ids() == {4193}
    assert webdb.intro_subs(4193) == set()
    assert webdb.shot_path(4193, 5) is None


def test_both_kinds_are_counted_in_the_sync(site):
    res = _sync_with_shots(site, GAME_SHOT, INTRO_SHOT)
    assert "screenshots.jsonl" in res["changed"]
    assert res["shots"] == 2
