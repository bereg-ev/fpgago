"""library/sources/base.py — the pluggable source-adapter interface.

A Source turns a website/database into (a) search results and (b) resolvable
download items, in the library's vocabulary.  The CLI/GUI never knows about
site-specific HTML — only these dataclasses.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterable, Optional


@dataclass
class SearchResult:
    """One hit from a source — enough to show a picker and, later, resolve
    downloads.  A single title may yield many results (one per crack/group)."""
    title: str
    source: str
    source_ref: str                    # stable id at the source
    platform: str = "264"              # c64/c16/plus4/264/unknown (source's claim)
    group_name: Optional[str] = None   # cracker / release group
    release_name: Optional[str] = None
    year: Optional[int] = None
    publisher: Optional[str] = None
    genre: Optional[str] = None
    fmt: Optional[str] = None
    source_url: Optional[str] = None
    extra: dict = field(default_factory=dict)


@dataclass
class DownloadItem:
    """A concrete downloadable file for a SearchResult."""
    url: str
    filename: str
    fmt: Optional[str] = None
    platform: Optional[str] = None
    group_name: Optional[str] = None
    release_name: Optional[str] = None
    # Source-specific post-download knowledge.  The MS-DOS adapter puts the
    # item's `emulator_start` here — the launch path the boot-disc builder
    # writes into AUTOEXEC.BAT.
    extra: dict = field(default_factory=dict)


class Source:
    """Base class. Adapters override name/platforms and the methods they can
    support; unsupported ones raise NotImplementedError and the CLI skips them.
    """
    name: str = "base"
    platforms: tuple = ()              # empty = platform-agnostic

    def search(self, query: str,
               platform: Optional[str] = None) -> list[SearchResult]:
        """Search the source. `platform` lets platform-agnostic adapters
        (e.g. Internet Archive) scope the query; single-platform adapters
        may ignore it."""
        raise NotImplementedError

    def resolve(self, result: SearchResult) -> list[DownloadItem]:
        """Return the downloadable files for a search result."""
        raise NotImplementedError

    def list_all(self, platform: Optional[str] = None) -> Iterable[SearchResult]:
        """Enumerate the source's whole catalog (for bulk sync, e.g. the full
        C16 set). Optional — raise NotImplementedError if unsupported."""
        raise NotImplementedError


REGISTRY: dict[str, Source] = {}


def register(source: Source):
    REGISTRY[source.name] = source
    return source
