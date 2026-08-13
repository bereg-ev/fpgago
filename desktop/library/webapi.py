"""library/webapi.py — the half of fpgago.com that knows who you are.

Reading the game database needs nothing (library/webdb.py).  Sending
something back — a verdict, the settings a game needed, a screenshot — is
signed in, with the account already registered on the website.

The password is traded once for a token and never stored.  The token lives in
a plain file in the library directory, mode 0600, the same shape `gh` uses:
a keyring dependency would be a hard requirement on three platforms for a
credential whose worst-case abuse is posting a wrong verdict about a 1983
game.

Separate from fetch.py because that module is deliberately a GET-only polite
cache for other people's servers, and this one is neither: no caching, no
throttle worth the name, POST bodies, and an Authorization header.  Stdlib
only, like the rest of `library/`.
"""

from __future__ import annotations

import json
import mimetypes
import os
import urllib.error
import urllib.request
import uuid
from typing import Optional

from . import canon, config, webdb

USER_AGENT = "fpgago-library/1.0 (desktop client)"
TIMEOUT = 60.0


class WebAPIError(Exception):
    """The server refused, or could not be reached.

    `code` is the server's machine-readable reason ('bad_credentials',
    'email_unverified', 'rate_limited', …) when there was one."""

    def __init__(self, message: str, code: str = "", status: int = 0):
        super().__init__(message)
        self.code, self.status = code, status


class NotLoggedIn(WebAPIError):
    """There is no token on this machine."""


# ── the token file ─────────────────────────────────────────────────────────

def token_path() -> str:
    return os.path.join(config.games_root(), "auth-token")


def load_token() -> Optional[str]:
    try:
        with open(token_path(), encoding="utf-8") as fh:
            return fh.read().strip() or None
    except OSError:
        return None


def save_token(token: str):
    path = token_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # Written 0600 from the start rather than chmod'ed afterwards: between the
    # two there is a moment when anybody on the machine can read it.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(token + "\n")


def clear_token():
    try:
        os.remove(token_path())
    except OSError:
        pass


def logged_in() -> bool:
    """Whether this machine holds a token.  Says nothing about whether the
    server still honours it — `whoami()` is the question that costs a
    request."""
    return load_token() is not None


# ── requests ───────────────────────────────────────────────────────────────

def _request(method: str, path: str, *, data: bytes = None,
             content_type: str = None, token: Optional[str] = None,
             timeout: float = TIMEOUT) -> dict:
    url = webdb.api_url(path)
    headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
    if content_type:
        headers["Content-Type"] = content_type
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers,
                                 method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            body = json.loads(raw)
        except ValueError:
            body = {}
        raise WebAPIError(
            body.get("error") or f"{url}: HTTP {e.code}",
            code=body.get("code", ""), status=e.code) from e
    except urllib.error.URLError as e:
        raise WebAPIError(f"cannot reach {url}: {e.reason}") from e
    try:
        return json.loads(raw)
    except ValueError as e:
        raise WebAPIError(f"{url}: response was not JSON") from e


def _authed(method: str, path: str, **kw) -> dict:
    token = kw.pop("token", None) or load_token()
    if not token:
        raise NotLoggedIn("not logged in — run `library login` first")
    return _request(method, path, token=token, **kw)


def post_json(path: str, payload: dict, *, token: Optional[str] = None) -> dict:
    return _authed("POST", path,
                   data=json.dumps(payload).encode("utf-8"),
                   content_type="application/json", token=token)


def post_multipart(path: str, fields: dict, files: dict, *,
                   token: Optional[str] = None) -> dict:
    """A multipart/form-data POST, hand-rolled.

    `files` is {field: path}.  Small by design — a screenshot is capped at a
    couple of megabytes — so the body is built in memory rather than
    streamed."""
    boundary = "----fpgago" + uuid.uuid4().hex
    out = bytearray()
    for name, value in fields.items():
        out += (f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
                f"{value}\r\n").encode("utf-8")
    for name, path_ in files.items():
        filename = os.path.basename(path_)
        ctype = mimetypes.guess_type(filename)[0] or "application/octet-stream"
        with open(path_, "rb") as fh:
            blob = fh.read()
        out += (f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="{name}"; '
                f'filename="{filename}"\r\n'
                f"Content-Type: {ctype}\r\n\r\n").encode("utf-8")
        out += blob + b"\r\n"
    out += f"--{boundary}--\r\n".encode("utf-8")
    return _authed("POST", path, data=bytes(out),
                   content_type=f"multipart/form-data; boundary={boundary}",
                   token=token)


# ── the account ────────────────────────────────────────────────────────────

def login(username: str, password: str, device: str = "") -> dict:
    """Trade the website password for a token, and remember the token.

    Returns {"user": …}.  Raises WebAPIError with code 'bad_credentials' or
    'email_unverified' — the second one is worth showing as itself, since it
    means "finish registering", not "you typed it wrong"."""
    res = _request("POST", "/api/v1/auth/token",
                   data=json.dumps({
                       "username": username, "password": password,
                       "device": device or _device_name(),
                   }).encode("utf-8"),
                   content_type="application/json")
    token = res.get("token")
    if not token:
        raise WebAPIError("server did not return a token")
    save_token(token)
    return {"user": res.get("user") or username}


def logout() -> dict:
    """Revoke this machine's token server-side, then forget it locally.

    The local file goes even if the server cannot be reached: "log me out"
    has to mean the credential is off this machine, whatever the network is
    doing."""
    result = {"revoked": False}
    try:
        _authed("POST", "/api/v1/auth/revoke",
                data=b"{}", content_type="application/json")
        result["revoked"] = True
    except NotLoggedIn:
        pass
    except WebAPIError as e:
        result["error"] = str(e)
    clear_token()
    return result


def whoami() -> Optional[dict]:
    """Who the server thinks this client is, or None when not logged in or
    the token has been revoked.  Never raises for the ordinary cases — it is
    called to decide what a menu should say."""
    try:
        return _authed("GET", "/api/v1/whoami")
    except NotLoggedIn:
        return None
    except WebAPIError as e:
        if e.status in (401, 403):
            return None
        raise


def _device_name() -> str:
    import platform
    try:
        return f"{platform.node()} ({platform.system()})"[:120]
    except Exception:                                    # noqa: BLE001
        return "desktop"


# ── sending results ────────────────────────────────────────────────────────

def submit_reports(reports: list) -> dict:
    """Send compat verdicts.  `reports` are compat.jsonl-shaped dicts.

    Returns {"accepted": n, "rejected": [{"index", "error"}]} — the server
    takes what it can and says exactly what it would not, so one bad line
    never costs the good ones."""
    clean = [{k: v for k, v in r.items()
              if not k.startswith("_") and k != "shared"}
             for r in reports]
    return post_json("/api/v1/compat", {"reports": clean})


def set_multiplayer(canon_id: int, on: bool) -> dict:
    """Tick or untick the game's multiplayer flag, for everyone.

    A property of the game itself, so no `sub`: every release of a two-player
    game seats two players.  The server republishes the platform files that
    carry the game, so other clients see the change on their next sync."""
    return post_json("/api/v1/game/multiplayer",
                     {"game": canon.format_id(canon_id),
                      "multiplayer": bool(on)})


def upload_screenshot(canon_id: int, path: str,
                      sub: Optional[int] = None) -> dict:
    """Send one picture.

    With no `sub` it is the GAME's picture — the one everybody's list shows
    for every release of it.  With a `sub` it is that one release's crack
    intro, which is extra rather than a replacement: the two are kept apart
    server-side and neither can depose the other."""
    ident = str(canon_id) if sub is None else f"{canon_id}/{sub}"
    return post_multipart("/api/v1/screenshot", {"game": ident},
                          {"image": path})
