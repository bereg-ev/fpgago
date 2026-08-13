"""library/ingest.py — put a file (local or downloaded) into the catalog.

One pipeline for both flows: classify → hash → dedup by sha1 → materialise
game/variant/file rows.  The classifier's verdict fills machine_detected;
source metadata (when present) sets the authoritative variant.platform and,
crucially, resolves the c16-vs-plus4 split the content sniff leaves at "264".
"""

from __future__ import annotations

import os
import shutil
from typing import Optional

from . import classify, config
from .db import Catalog, GameRow, VariantRow, FileRow, PLATFORM_264


def _title_from_filename(path: str) -> str:
    base = os.path.splitext(os.path.basename(path))[0]
    return base.replace("_", " ").replace("-", " ").strip() or base


def ingest_file(cat: Catalog, path: str, *,
                title: Optional[str] = None,
                platform: Optional[str] = None,     # source's authoritative claim
                group_name: Optional[str] = None,
                release_name: Optional[str] = None,
                year: Optional[int] = None,
                publisher: Optional[str] = None,
                source: str = "local",
                source_ref: Optional[str] = None,
                source_url: Optional[str] = None,
                copy_into_library: bool = True) -> dict:
    """Classify + register one local file. Returns a summary dict."""
    with open(path, "rb") as fh:
        data = fh.read()
    sha1, crc32 = classify.hashes(data)

    existing = cat.find_by_hash(sha1=sha1)
    verdict = classify.classify_path(path)
    name_plat, _ = classify.platform_from_name(path)

    # Platform precedence (best signal first):
    #   1. an authoritative source tag (e.g. Plus4World memoryreq 16K/64K),
    #   2. a filename/folder hint (TOSEC set name, "c16"/"+4" token),
    #   3. the content verdict (load address; >16K ⇒ plus4),
    #   4. "264" (c16-or-plus4, unresolved) as the honest fallback.
    if platform and platform != PLATFORM_264:
        plat = platform
    elif name_plat:
        plat = name_plat
    elif verdict.platform in ("c64", "c16", "plus4"):
        plat = verdict.platform
    else:
        plat = PLATFORM_264

    title = title or _title_from_filename(path)
    gid = cat.upsert_game(GameRow(title, year=year, publisher=publisher))
    vid = cat.upsert_variant(gid, VariantRow(
        platform=plat, source=source, source_ref=source_ref or sha1,
        group_name=group_name, release_name=release_name, year=year,
        fmt=verdict.fmt, source_url=source_url))

    dest = path
    if copy_into_library:
        d = config.platform_dir(plat, title)
        dest = os.path.join(d, os.path.basename(path))
        if os.path.abspath(dest) != os.path.abspath(path):
            shutil.copy2(path, dest)

    fid = cat.add_file(vid, FileRow(
        filename=os.path.basename(path), path=dest, size=len(data),
        sha1=sha1, crc32=crc32, load_addr=verdict.load_addr,
        mem_top=verdict.mem_top, machine_detected=verdict.platform,
        confidence=verdict.confidence,
        status="downloaded" if copy_into_library else "verified"))
    cat.commit()
    return {"game_id": gid, "variant_id": vid, "file_id": fid,
            "platform": plat, "verdict": verdict, "sha1": sha1, "crc32": crc32,
            "duplicate": existing is not None, "path": dest}


GAME_EXTS = (".prg", ".d64", ".g64", ".d81", ".tap", ".t64", ".crt", ".zip",
             ".adf")


def index_tree(cat: Catalog, root: str, *, tosec=None,
               copy_into_library: bool = False, progress=None) -> dict:
    """Walk a local collection and catalog every game file.

    For each file: hash it, and if a TOSEC index is supplied, look the hash up
    to get the canonical title, platform (from the DAT set) and cracker GROUP
    (from the [cr ...] flag) — the authoritative identity for a loose file.
    Files with no TOSEC hit fall back to the content classifier + path hints.
    """
    from .classify import hashes
    stats = {"scanned": 0, "indexed": 0, "tosec_hits": 0, "dupes": 0,
             "by_platform": {}}
    for dirpath, _, files in os.walk(root):
        for fn in sorted(files):
            if os.path.splitext(fn)[1].lower() not in GAME_EXTS:
                continue
            path = os.path.join(dirpath, fn)
            stats["scanned"] += 1
            kw = {}
            if tosec is not None:
                try:
                    with open(path, "rb") as fh:
                        sha1, crc32 = hashes(fh.read())
                except OSError:
                    continue
                hit = tosec.lookup(sha1=sha1, crc32=crc32)
                if hit:
                    stats["tosec_hits"] += 1
                    kw = dict(title=hit.base_title, platform=hit.platform,
                              group_name=hit.group, source="tosec",
                              source_ref=sha1,
                              release_name=("+".join(hit.flags) or None))
            try:
                r = ingest_file(cat, path, copy_into_library=copy_into_library,
                                **kw)
            except Exception as e:
                if progress:
                    progress(f"! {fn}: {e}")
                continue
            stats["indexed"] += 1
            stats["dupes"] += 1 if r["duplicate"] else 0
            stats["by_platform"][r["platform"]] = \
                stats["by_platform"].get(r["platform"], 0) + 1
            if progress:
                progress(f"  {r['platform']:5} {fn}")
    return stats
