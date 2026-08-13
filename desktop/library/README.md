# fpgago game library

Local copy of the fpgago game database, plus everything that turns an entry
in it into a game running on the board. Standalone and headless (stdlib
only); the desktop GUI drives the same code.

**Where the data comes from (changed 2026-08-05).** The catalog is no longer
built by each user's machine scraping the archives. `fpgago.com` does that
once for everybody — it reads the archives, applies the project's
corrections, and hands out the permanent IDs — and clients download the
result:

```
python3 -m library.cli sync          # only the files whose sha1 changed
```

Search then runs entirely on that local copy, so it is instant, complete and
works offline. What still goes out to the archives is the **game file
itself**: fpgago.com serves metadata and screenshots only, so downloading a
release fetches it from whoever hosts it (`sources/*.resolve()`).

Sending results *back* — verdicts, per-game settings, screenshots — needs the
account you already have on the website:

```
python3 -m library.cli login
python3 -m library.cli compat share
```

Two board-facing rules, both fixed on 2026-08-05 after a board session:

* **The flash name carries the canon id** —
  `c64-wizard_of_wor-bandit-4193.5.d64`.  Two releases of one game usually
  download under the same filename and the flash FS replaces a file of the
  same name, so the second "Send to board" silently overwrote the first, and
  a compatibility verdict could not say which release was tested.
  `board_name(path, platform, ident, title=, group=)` builds the stem from
  the game's identity and appends the id last, never truncating the id.
* **Search matches word by word, not as one phrase** — "wizard wor" finds
  "Wizard of Wor".  A user's typing is not a contiguous substring of the
  title; `search_local()` ANDs one LIKE per word and keeps whole-phrase and
  first-word-prefix hits at the top.

## Layout

```
library/
  db.py          SQLite catalog: game / variant / file, + title matching
  canon.py       ABSOLUTE game IDs (#1234-K) + the committed registry
  patches.py     committed corrections to what the sources say (re-applied
                 on every catalog open, so a re-fetch cannot undo them)
  classify.py    content classifier ($0801=C64, $1001=264; c16-vs-plus4 by
                 memory footprint) + crc32/sha1 hashing (variation identity)
  ingest.py      classify → hash → dedup → register a file into the catalog
  config.py      library root (~/fpgago-games, or $FPGAGO_GAMES)
  fetch.py       polite cached HTTP (rate-limited, disk cache) — stdlib urllib
  webdb.py       sync the game database from fpgago.com (manifest -> only
                 the files that changed -> local SQLite)
  webapi.py      the signed-in half: login, send verdicts and screenshots
  board.py       push a game to the board flash (upload + CRC verify + run)
  compat.py      shared works/issues/broken database (git-tracked JSONL)
  sources/       download adapters — resolve() only; the searching half of
                 these now runs on the server (fpgago-web/apps/gamedb/scrape)
  data/          FROZEN seed files, kept so a checkout with no network still
                 has the ID space. The live copies live on fpgago.com.
                 canon.jsonl — the ID registry as of 2026-08-05
                 compat.jsonl — verdicts as of 2026-08-05 (superseded by the
                 synced copy in <games>/cache/compat/ as soon as you sync)
                 compat-local.jsonl — YOUR verdicts, gitignored, until shared
                 patches.jsonl — corrections, now also held server-side
  cli.py         `python3 -m library.cli ...`
  tests/         network-free unit tests
```

## Absolute game IDs (`canon.py`)

Every game has one permanent project-wide ID — the same for every user, so
`#2862-A` means *Pirates* everywhere (forums, COMPATIBILITY.md, bug reports):

- **`#2862-A`** — the game; `A` is a check character (weighted mod-23 over the
  digits, alphabet skips I/L/O) so a typo'd or transposed ID is rejected at
  parse time, not resolved to the wrong game.
- **`#2862-A/2`** — one specific release/crack (a *variant*).

The registry `library/data/canon.jsonl` is **committed to git** and is pure
metadata — titles, years, groups, source URLs, content hashes — no game
content, so nothing copyrighted ships with the repo. It is **append-only**:
an ID once published is never reassigned. Three checksum layers guard it:
the ID check char, an integrity footer (sha1 of the whole file — a corrupted
registry refuses to load), and per-release **content hashes** so a download
is verified byte-identical to what the ID was assigned to.

A fresh checkout auto-imports the registry into the local SQLite catalog on
first CLI use.

**IDs are minted on the server**, when a release enters the catalog there —
so everything that arrives through `sync` already carries its ID and every
client agrees about it. They used to be minted locally, as `max(id)+1` over
the committed file, which only worked as long as everybody committed the same
append-only file in the same order; two people downloading on the same
evening got the same number.

A release this machine found by itself (an imported file, an indexed folder)
has no canon ID until the server has seen it. That still works — the flash
name falls back on the local row id — it just is not a name another machine
can resolve.

The same ID goes into the **name of the file on the board**:
`#4193-U/5` → `c64-wizard_of_wor-bandit-4193.5.d64`. That is what lets a
verdict be tied to the release that actually ran — before it, the flash name
carried a local SQLite row id that appeared in no list and meant nothing on
another machine, so twelve cracks of one game were twelve indistinguishable
files (board, 2026-08-05).

## Correcting the sources (`patches.py`)

The sources are raw material, and some of what they say is wrong.
archive.org's `Wizard_of_Wor_1983_Commodore_cr_ATG` is not Wizard of Wor: the
disk holds none of the game's files and boots EA's platform game *Wizard*
instead. Finding that out costs a download, an upload and a confused minute
in front of the board — so it is written down once, in
**`library/data/patches.jsonl`** (committed, metadata only), and re-applied
**every time a catalog is opened**. A re-search, a bulk `index` of a whole
collection, or a fresh checkout cannot undo it.

```jsonc
{"source":"archive","ref":"Wizard_of_Wor_1983_Commodore_cr_ATG",
 "title":"Wizard","game_canon":4188,           // re-file under the right game
 "note":"Mislabeled at the source: ...",       // shown on the row, with a ⚠
 "by":"d64 directory + loader disassembly, 2026-08-05"}
```

Match on `source`+`ref` or on `sha1` (which survives the source renaming its
item). Set `title`/`game_canon` (re-file), `platform`, `group`, `release`,
`year`, `note`, or `drop: true` (a bad dump — kept, but not listed). Unknown
field names are an error at load time, so a typo cannot become a correction
that silently does nothing.

    python3 -m library.cli patch list | verify | apply

Re-filing a release that already had a canon ID does **not** reassign or
delete that ID — the old entry keeps a `moved` pointer to the new one, so a
verdict someone filed under it still leads somewhere.

## The three-level model

- **game** — the abstract work, matched across sources by a normalized title
  (`"The Last Ninja II (1988) [Nostalgia]"` → `last ninja 2`).
- **variant** — one release on one platform: the `(group, release, platform,
  source)` tuple. This is what you pick when a game *needs a specific version
  to run* during validation (`validated` flag per variant).
- **file** — a concrete local file + the classifier's verdict and content
  hashes. **sha1** = exact dedup key; **crc32** cross-references TOSEC / GB64.

## Platform classification

Primary signal is the source database (Plus4World tags C16 vs Plus4; GB64/CSDb
are C64). The content classifier is the cross-check / fallback for loose files:

| load address | platform | note |
|---|---|---|
| `$0801` | **C64** | BASIC start — high confidence |
| `$1001`, mem_top ≤ `$3FFF` | **C16** | fits 16 KB (also runs on Plus4) |
| `$1001`, mem_top > `$3FFF` | **Plus/4** | needs > 16 KB — can't be C16 |

The C16↔Plus4 split from content is reliable for single-file PRGs, only a hint
for `.d64` multi-loaders (first file is a small loader) — so source metadata
wins, and every verdict carries a confidence.

## Source adapters (`sources/`)

| adapter | platforms | role | how |
|---|---|---|---|
| **plus4world** | c16 / plus4 | THE 264 DB; authoritative 16K/64K tag; **full C16 set** | HTML scrape of `plus4world.powweb.com` (`.com` is dead) |
| **archive** | c64 (+ any) | online search + anonymous download; fetch TOSEC/GB64 | JSON APIs (advancedsearch / metadata / download) |
| **csdb** | c64 | per-group crack attribution (variation) | XML webservice, **by-ID** (open API has no free-text search) |
| **gb64** | c64 | rich C64 metadata enrichment (cracker/year/publisher/genre) | **local** `gb64.sqlite`/`.mdb` (site 403s bots) |
| **tosec** | all | hash → canonical title + platform + `[cr]` group (identity) | local `.dat` (ClrMamePro XML) |

All web access goes through `fetch.py`: descriptive User-Agent (deliberately
*not* an AI-bot UA — CSDb/others block those), ≥1 s/host throttle, 7-day disk
cache. Plus4World is `Allow: /`; Archive.org 429-throttles under load.

## CLI

```sh
python3 -m library.cli sync                            # get the latest database
python3 -m library.cli sync c64 --no-screenshots       # ...just what you need
python3 -m library.cli sync-status                     # what you have (no network)
python3 -m library.cli login | logout | whoami         # the fpgago.com account
python3 -m library.cli classify game.prg disk.zip     # print verdicts
python3 -m library.cli index   ~/roms --tosec ~/dats  # catalog a local collection
python3 -m library.cli import  *.prg *.d64            # register a few local files
python3 -m library.cli search  "boulder dash" [--platform c64]
python3 -m library.cli show     2862-A                 # resolve an absolute ID
python3 -m library.cli variants 2862-A                 # cracks/groups of the game
python3 -m library.cli download 2862-A/2 --upload --run  # fetch → board → play
python3 -m library.cli upload   2862-A/2 [--run]       # push an already-local file
python3 -m library.cli patch list | verify | apply     # source corrections
python3 -m library.cli canon-verify                    # integrity-check a registry
python3 -m library.cli screenshot 2862-A shot.png      # the game's own picture
python3 -m library.cli screenshot 2862-A/2 intro.png   # that release's crack intro
python3 -m library.cli compat report 2862-A works --machine c64 --mode auto
python3 -m library.cli compat report 2862-A issues --machine c64 --drive dos
python3 -m library.cli compat report 2862-A works --machine c64 --real1541 \
        --notes "fastload dies in the loader" --email you@example.com
python3 -m library.cli compat list --by you@example.com [--real1541]
python3 -m library.cli compat show 2862-A | list | verify
python3 -m library.cli compat profile 2862-A [--machine c64]
python3 -m library.cli compat report 2862-A works --machine c64 --local
python3 -m library.cli compat share [--route url|gh|file|print]
python3 -m library.cli sources | stats
```

**Compatibility database:** `data/compat.jsonl`, git-tracked and append-only
— one JSON line per verdict, so concurrent reports merge cleanly. IDs must
carry their check character, so a typo can't tag the wrong game; newest
report per (game, machine) is the current verdict and `show` displays it.
Narrative failure analysis stays in `retro-arch/COMPATIBILITY.md`.

**"Needs the real 1541" (`real1541`).** A boolean on the report, separate
from `mode`: `mode` is how one test happened to be run, `real1541: true` is
the finding that *no* fastload path serves this game and only the
cycle-accurate 1541 emulation will run it. It is what the Library tab's
**Real 1541** search box filters on, and flagged games say `1541 only` in
their *tested on* column. Like `profile`, a later report that says nothing
about the drive does not clear it — an explicit `real1541: false`
(`--no-real1541`, or un-ticking the box in the app) is how it is taken back,
so "I retested it and it still works" cannot silently lose the finding. A
game flagged on one machine and cleared on another stays in the list: the
limitation is real somewhere.

**Who tested it (`by`, `email`).** Every report carries a name and, when one
has been given, an address — which is what makes a handful of testers
reviewable: `compat list --by <name-or-email>` reads back one person's
results, and a surprising verdict has somebody to ask. Both are typed once
(desktop app: Settings… → *Tested by* / *Email*; headless: `--by`/`--email`
or `$FPGAGO_EMAIL`) and remembered in `<games>/reporter.json`, falling back
to `git config user.name` / `user.email`. The address is validated before it
is stored — a report nobody can follow up on is the thing the field exists
to prevent — and stays optional.

**Whose verdict is it?** Three files feed the same view and are kept apart on
purpose: `data/compat.jsonl` (shipped with the checkout), a cached copy
**downloaded** from the project (so a checkout that is never `git pull`ed
still learns what other people found), and `data/compat-local.jsonl` — your
own. `compat.load_tagged()` marks each report `yours` or `online`, and the
Library tab shows both: a mark of your own is upright, one that only comes
from the database is italic, and where they disagree the row turns into
`c64 ✓ yours ≠ ✗ online` with a tooltip spelling it out. Your own result is
what the app acts on — you tested it, they didn't — but the clash is never
hidden, and `Tested: ≠ yours differs from online` lists exactly those games.

**Reporting without git (`share.py`).** "Fork the repo, commit a line, open
a PR" is where most people's evening ends, so nothing in the app requires
it. A user's own verdicts go to `data/compat-local.jsonl` (gitignored, read
back immediately, never conflicts with a `git pull`), and the app offers
three ways out, best-available first: submit through the **`gh` CLI** if it
is installed and logged in; open a **pre-filled GitHub issue** in the
browser (a GitHub account, nothing else); or just take the **text** —
clipboard or a file — and send it however. The issue body carries the exact
JSONL a maintainer pastes into `compat.jsonl`. Headless equivalent:
`compat report … --local` then `compat share`. Reports are stamped as sent
only when a route actually delivered them, so a cancelled dialog loses
nothing.

**Per-game settings (`profile.py`):** a report may carry an optional
`"profile"` — the per-game settings the board applies when that game
launches (drive mode, CPU speed, button mapping, start-up key macro), as
≤255 bytes of `key=value` text. The format is the firmware's. This closes a loop
the database already half-had: `"mode":"auto"` was a per-game setting
written down and then applied *by hand*. Now `upload`/`download --upload`
looks up the game's profile and writes it to the board's KV store
(`g.<flash-name>`) with the file — no new protocol, `HL_CMD_KV_SET` has
always been there. Build one with `--drive/--speed/--btn/--type` or pass
`--profile` raw; `compat verify` rejects an oversized or malformed profile
in CI, and only *warns* about keys or key-names it doesn't recognise, so the
database can carry a profile a newer firmware understands. A later verdict
without a `profile` does **not** erase an earlier one — "I retested it" must
not silently drop the settings the game needed. `--no-profile` skips the
push.

In the **desktop app** the same settings are editable in two places, with one
dialog:

- **Board tab → Settings…** (or double-click a game) edits the copy *on the
  board* — read from and written to `g.<flash-name>` in the MCU KV store.
- **Library tab → Settings…** edits the copy *in the database* — filed per
  game and machine, which is what a download brings along and an upload
  writes to the board. This is also the **review** form: alongside the
  verdict it carries the *needs the real 1541* box (ticking it pins the drive
  mode to match), free-text **notes**, and who tested it. All of them are per
  machine, so switching the machine combo switches the notes and the flag
  with the settings.

Either way the dialog shows one row per setting with *Use global* first,
validates as you type (byte count, bad macro steps), and preserves keys it
doesn't recognise — so it can round-trip a profile written by a newer
firmware.

The start-up keys are **one action per row**, not a macro string: *wait for
the machine to start · type `load"*",8,1` + Return · wait for the game to
load · wait 3 s · press C= · wait 4 s · fire*. The grammar conversion lives
in `profile.parse_macro` / `build_macro`, so the same list is testable
without a GUI, and `describe_macro()` says the whole thing back in one
English sentence. Joystick steps are stored and shipped but the firmware
does not press them yet (profiles plan, phase 5) — the editor says so
rather than pretending.

**Send to board** / **Send & play ▶** on the Library tab is the whole loop in
one click: download the game if it isn't on disk yet, upload + CRC-verify,
write its settings, and start it.
Tests: `desktop/.venv/bin/python3 -m pytest library/tests -q` (the GUI tests
skip without PySide6).

**Straight to the board:** `download <ID> --upload --run` closes the whole
loop — fetch, verify against the canon hash, name the file for the BIOS
(`c64-…`), upload over hostlink (or console XMODEM-1K fallback), CRC-check
what landed in flash, then mount + `LOAD"*",8,1` + `RUN`. A `.prg` is
auto-wrapped into a bootable `.d64` when `--run` is asked. Needs pyserial
(`make desktop-venv`, or any python with pyserial); the port autodetects
(`--port` to override) and must not be held open by a serial terminal.

The headline flows: **`sync`** brings down the whole database (and is cheap
to repeat — only changed files move); **`search`** then answers from it
instantly and offline; **`download`/`upload`** fetch a release from the
archive that hosts it and push it to the board; **`index --tosec`** turns an
existing local collection into a classified, variation-aware catalog (TOSEC
hashes give canonical title + platform + cracker group).

### Trying it against a local server

```sh
# in fpgago-web:
python manage.py migrate
python manage.py gamedb_seed_canon   --path ../fpgago/desktop/library/data/canon.jsonl
python manage.py gamedb_seed_compat  --path ../fpgago/desktop/library/data/compat.jsonl
python manage.py gamedb_seed_patches --path ../fpgago/desktop/library/data/patches.jsonl
python manage.py gamedb_publish
python manage.py runserver 8123

# in fpgago/desktop:
export FPGAGO_WEB_URL=http://127.0.0.1:8123 FPGAGO_GAMES=/tmp/gl
python3 -m library.cli sync
python3 -m library.cli login
```

## Status

- ✅ DB, classifier (+ path hints + `.crt`), ingest, local indexer, CLI,
  tests (`python3 library/tests/test_library.py`).
- ✅ All 5 adapters (plus4world, archive, csdb, gb64, tosec) — verified live
  except gb64 (needs a local DB) and the full 72-page C16 crawl.
- ⏳ Wiring into the PySide6 GUI (D4) — this package is the engine it drives.
- ⏳ `download` for CSDb `.zip` releases unpacks nothing yet (stores the zip;
  the classifier already reaches inside zips for `classify`).
