"""library/config.py — where the library lives on disk.

Default layout is INSIDE the repo so the collection travels with the project
and a fresh checkout finds it in a predictable place:

    <repo>/game-library/
        library.db                 # the SQLite catalog
        cache/<source>/...         # cached source responses + raw downloads
        <platform>/<title>/...     # imported game files

`game-library/` is gitignored (large / copyrighted dumps) and is never touched
by `make clean` (clean only sweeps arch/, util/, games/, */sim-desktop). Point
the library somewhere else — e.g. an external drive — with $FPGAGO_GAMES.
"""

from __future__ import annotations
import os


def _repo_root() -> str:
    # config.py lives at <repo>/desktop/library/config.py.
    here = os.path.dirname(os.path.abspath(__file__))   # <repo>/desktop/library
    return os.path.dirname(os.path.dirname(here))       # <repo>


def games_root() -> str:
    env = os.environ.get("FPGAGO_GAMES")
    if env:
        return os.path.expanduser(env)
    return os.path.join(_repo_root(), "game-library")


def db_path() -> str:
    return os.path.join(games_root(), "library.db")


def cache_dir(source: str = "") -> str:
    d = os.path.join(games_root(), "cache", source)
    os.makedirs(d, exist_ok=True)
    return d


def platform_dir(platform: str, title: str) -> str:
    # Filesystem-safe title.
    safe = "".join(c if c.isalnum() or c in " -_.()" else "_" for c in title).strip()
    d = os.path.join(games_root(), platform, safe or "untitled")
    os.makedirs(d, exist_ok=True)
    return d
