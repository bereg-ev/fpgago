"""Signing in to fpgago.com, and sending results back.

Served by a loopback HTTP server that answers like the real API, because the
things worth pinning are the wire shape (Bearer header, multipart body), the
token file's permissions, and — most of all — that a report the server
refused is NOT marked as sent.
"""

from __future__ import annotations

import json
import os
import stat
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from library import compat, webapi


class FakeAPI:
    """Just enough of /api/v1 to drive the client."""

    def __init__(self):
        self.requests: list[tuple[str, str, dict]] = []
        self.token = "tok-abc123456789"
        self.reject_indices: set[int] = set()
        self.login_error = None
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def _body(self):
                n = int(self.headers.get("Content-Length", 0) or 0)
                return self.rfile.read(n)

            def _send(self, code, payload):
                raw = json.dumps(payload).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(raw)))
                self.end_headers()
                self.wfile.write(raw)

            def _auth_ok(self):
                return (self.headers.get("Authorization")
                        == f"Bearer {outer.token}")

            def do_POST(self):
                raw = self._body()
                outer.requests.append((self.path, dict(self.headers), raw))

                if self.path == "/api/v1/auth/token":
                    if outer.login_error:
                        code, err = outer.login_error
                        return self._send(code, {"error": "nope", "code": err})
                    body = json.loads(raw)
                    return self._send(200, {"token": outer.token,
                                            "user": body["username"]})
                if not self._auth_ok():
                    return self._send(401, {"error": "bad token",
                                            "code": "bad_token"})
                if self.path == "/api/v1/auth/revoke":
                    outer.token = "revoked"
                    return self._send(200, {"ok": True})
                if self.path == "/api/v1/compat":
                    reports = json.loads(raw)["reports"]
                    rejected = [{"index": i, "error": "no such game"}
                                for i in sorted(outer.reject_indices)
                                if i < len(reports)]
                    return self._send(200, {
                        "accepted": len(reports) - len(rejected),
                        "rejected": rejected})
                if self.path == "/api/v1/screenshot":
                    return self._send(200, {"ok": True, "bytes": len(raw)})
                if self.path == "/api/v1/game/multiplayer":
                    body = json.loads(raw)
                    return self._send(200, {"ok": True, "id": body["game"],
                                            "multiplayer": body["multiplayer"],
                                            "published": True})
                return self._send(404, {"error": "no", "code": "nope"})

            def do_GET(self):
                outer.requests.append((self.path, dict(self.headers), b""))
                if self.path == "/api/v1/whoami":
                    if not self._auth_ok():
                        return self._send(401, {"error": "bad token",
                                                "code": "bad_token"})
                    return self._send(200, {"user": "tester",
                                            "device": "laptop"})
                return self._send(404, {"error": "no", "code": "nope"})

            def log_message(self, *a):
                pass

        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.httpd.server_address[1]}"

    def posted_to(self, path):
        return [r for r in self.requests if r[0] == path]

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()


@pytest.fixture
def api(tmp_path, monkeypatch):
    monkeypatch.setenv("FPGAGO_GAMES", str(tmp_path / "games"))
    server = FakeAPI()
    monkeypatch.setenv("FPGAGO_WEB_URL", server.url)
    yield server
    server.stop()


# ── the token ──────────────────────────────────────────────────────────────

def test_login_stores_the_token_readable_only_by_its_owner(api):
    res = webapi.login("tester", "sekrit")
    assert res["user"] == "tester"
    assert webapi.load_token() == api.token

    mode = stat.S_IMODE(os.stat(webapi.token_path()).st_mode)
    assert mode == 0o600, f"token file is {oct(mode)}, must be 0600"

    # The password went once and was not kept anywhere.
    sent = json.loads(api.posted_to("/api/v1/auth/token")[0][2])
    assert sent["password"] == "sekrit"
    assert "sekrit" not in open(webapi.token_path()).read()


def test_login_reports_an_unverified_account_as_itself(api):
    """"Finish registering" and "you typed it wrong" are different problems
    and the user can only fix one of them."""
    api.login_error = (403, "email_unverified")
    with pytest.raises(webapi.WebAPIError) as e:
        webapi.login("tester", "sekrit")
    assert e.value.code == "email_unverified"
    assert webapi.load_token() is None


def test_login_reports_bad_credentials(api):
    api.login_error = (401, "bad_credentials")
    with pytest.raises(webapi.WebAPIError) as e:
        webapi.login("tester", "wrong")
    assert e.value.code == "bad_credentials"


def test_whoami_needs_no_login_to_answer_no(api):
    assert webapi.logged_in() is False
    assert webapi.whoami() is None


def test_whoami_after_login(api):
    webapi.login("tester", "sekrit")
    assert webapi.whoami() == {"user": "tester", "device": "laptop"}
    _p, headers, _b = api.posted_to("/api/v1/whoami")[0]
    assert headers["Authorization"] == f"Bearer {api.token}"


def test_revoked_token_reads_as_logged_out(api):
    webapi.login("tester", "sekrit")
    api.token = "something-else"
    assert webapi.whoami() is None          # 401 is an answer, not a crash


def test_logout_removes_the_token_even_if_the_server_is_gone(api):
    webapi.login("tester", "sekrit")
    api.stop()
    webapi.logout()
    assert webapi.load_token() is None


def test_calls_without_a_token_say_so(api):
    with pytest.raises(webapi.NotLoggedIn):
        webapi.submit_reports([])


# ── sending reports ────────────────────────────────────────────────────────

REPORTS = [
    {"id": "#4193-U", "machine": "c64", "status": "works",
     "date": "2026-08-05", "by": "me", "_canon": 4193, "_sub": None},
    {"id": "#2862-A", "machine": "c64", "status": "issues",
     "date": "2026-08-05", "by": "me", "_canon": 2862, "_sub": None},
]


def test_submit_strips_internal_fields(api):
    """`_canon`/`_sub` are the parser's, not the wire's."""
    webapi.login("tester", "sekrit")
    webapi.submit_reports(REPORTS)
    sent = json.loads(api.posted_to("/api/v1/compat")[0][2])["reports"]
    assert sent[0] == {"id": "#4193-U", "machine": "c64", "status": "works",
                       "date": "2026-08-05", "by": "me"}


def test_submit_returns_what_was_refused(api):
    webapi.login("tester", "sekrit")
    api.reject_indices = {1}
    res = webapi.submit_reports(REPORTS)
    assert res["accepted"] == 1
    assert res["rejected"] == [{"index": 1, "error": "no such game"}]


def test_multiplayer_goes_up_as_the_plain_game_id(api):
    """The flag is the game's, so the wire carries "#4193-U" — never a /n —
    and a real boolean, not a string the server would refuse."""
    webapi.login("tester", "sekrit")
    res = webapi.set_multiplayer(4193, True)
    assert res["multiplayer"] is True
    sent = json.loads(api.posted_to("/api/v1/game/multiplayer")[0][2])
    assert sent == {"game": "#4193-U", "multiplayer": True}


def test_multiplayer_needs_a_login(api):
    with pytest.raises(webapi.NotLoggedIn):
        webapi.set_multiplayer(4193, True)


def test_backend_setter_updates_the_local_row_only_after_the_server(api):
    """lib.set_multiplayer is what the desktop checkbox calls: server first,
    then the local catalog — and nothing locally when the server refused, or
    a tick would quietly mean "only on this machine"."""
    from app import library_backend as lib
    from library import config
    from library.db import Catalog, GameRow

    c = Catalog(config.db_path())
    gid = c.upsert_game(GameRow("Wizard of Wor"))
    c.db.execute("UPDATE game SET canon_id=4193 WHERE id=?", (gid,))
    c.commit()
    c.close()

    def flag():
        c = Catalog(config.db_path())
        try:
            return c.db.execute("SELECT multiplayer FROM game WHERE id=?",
                                (gid,)).fetchone()[0]
        finally:
            c.close()

    with pytest.raises(webapi.NotLoggedIn):
        lib.set_multiplayer(4193, True)
    assert flag() == 0                       # refused = untouched

    webapi.login("tester", "sekrit")
    res = lib.set_multiplayer(4193, True)
    assert "multiplayer" in res["done"]
    assert flag() == 1
    lib.set_multiplayer(4193, False)
    assert flag() == 0


def test_screenshot_upload_is_multipart(api, tmp_path):
    webapi.login("tester", "sekrit")
    png = tmp_path / "shot.png"
    png.write_bytes(b"\x89PNG\r\n\x1a\n" + b"0" * 64)
    webapi.upload_screenshot(4193, str(png))

    _path, headers, raw = api.posted_to("/api/v1/screenshot")[0]
    assert headers["Content-Type"].startswith("multipart/form-data; boundary=")
    assert b'name="game"' in raw and b"4193" in raw
    assert b'name="image"; filename="shot.png"' in raw
    assert b"image/png" in raw
    assert b"\x89PNG" in raw


# ── the share route ────────────────────────────────────────────────────────

def _record(canon_id, machine="c64", status="works"):
    compat.append_report(canon_id=canon_id, sub=None, machine=machine,
                         status=status, local=True)


def test_share_route_appears_only_when_signed_in(api):
    from library import share
    assert [r["key"] for r in share.routes([])].count("web") == 0
    webapi.login("tester", "sekrit")
    routes = share.routes([])
    assert routes[0]["key"] == "web"
    assert "tester" in routes[0]["hint"]


def test_sharing_marks_only_what_the_server_took(api):
    """The report the server refused is the one the user most needs offered
    again — stamping it as sent would lose it silently."""
    from app import library_backend as lib
    webapi.login("tester", "sekrit")
    _record(4193)
    _record(2862, status="issues")
    assert len(compat.unshared()) == 2

    api.reject_indices = {1}
    res = lib.share_via("web")

    assert res["accepted"] == 1
    left = compat.unshared()
    assert len(left) == 1
    assert left[0]["_canon"] == 2862


def test_sharing_everything_leaves_nothing_waiting(api):
    from app import library_backend as lib
    webapi.login("tester", "sekrit")
    _record(4193)
    _record(2862)
    lib.share_via("web")
    assert compat.unshared() == []
