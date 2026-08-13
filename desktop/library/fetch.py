"""library/fetch.py — polite HTTP with on-disk caching (stdlib only).

Zero external deps (urllib) so the CLI runs on a bare python3.  All source
adapters go through here, which gives us one place to enforce good-citizen
behaviour: a descriptive User-Agent, a minimum delay between requests to the
same host, and a disk cache so re-running a search doesn't re-hit the site.
"""

from __future__ import annotations

import hashlib
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Optional

from . import config

USER_AGENT = ("fpgago-library/0.1 (personal FPGA retro-console game manager; "
              "+https://github.com/ contact via repo)")
MIN_INTERVAL = 1.0            # seconds between requests to the same host
_last_hit: dict[str, float] = {}


def _throttle(url: str):
    host = urllib.parse.urlparse(url).netloc
    now = time.time()
    wait = MIN_INTERVAL - (now - _last_hit.get(host, 0.0))
    if wait > 0:
        time.sleep(wait)
    _last_hit[host] = time.time()


def _cache_key(url: str) -> str:
    return hashlib.sha1(url.encode()).hexdigest()[:20]


def get(url: str, *, cache: bool = True, max_age: float = 7 * 86400,
        binary: bool = False, timeout: float = 30.0):
    """GET a URL as text (or bytes if binary=True), with a disk cache.

    Returns the body, or raises urllib.error.URLError on failure.
    """
    cdir = config.cache_dir("http")
    cpath = os.path.join(cdir, _cache_key(url) + (".bin" if binary else ".txt"))
    if cache and os.path.exists(cpath):
        if (time.time() - os.path.getmtime(cpath)) < max_age:
            mode = "rb" if binary else "r"
            with open(cpath, mode) as fh:
                return fh.read()

    _throttle(url)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    body = raw if binary else raw.decode("utf-8", "replace")
    if cache:
        mode = "wb" if binary else "w"
        with open(cpath, mode) as fh:
            fh.write(body)
    return body


def get_json(url: str, **kw):
    return json.loads(get(url, **kw))


# Archive.org sheds load with 429/500/503 — routinely, and on the download
# endpoint more than the API.  Those are "come back in a moment", not "this
# file does not exist", so they are worth a couple of backed-off retries.
RETRY_STATUS = (429, 500, 502, 503, 504)


def download(url: str, dest: str, *, timeout: float = 120.0,
             progress=None, retries: int = 3) -> int:
    """Stream a URL to a local file. Returns bytes written. Not cached (the
    file *is* the cache)."""
    os.makedirs(os.path.dirname(os.path.abspath(dest)), exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(retries):
        _throttle(url)
        total = 0
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp, \
                    open(dest, "wb") as out:
                size = int(resp.headers.get("Content-Length", 0) or 0)
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    out.write(chunk)
                    total += len(chunk)
                    if progress:
                        progress(total, size)
            return total
        except urllib.error.HTTPError as e:
            if e.code not in RETRY_STATUS or attempt == retries - 1:
                raise
            time.sleep(2.0 * (attempt + 1))
