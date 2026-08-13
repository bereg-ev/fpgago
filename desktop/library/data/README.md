# library/data — frozen seed files

**These files are no longer the live database.** As of 2026-08-05 the game
database lives on fpgago.com, which does the scraping, applies the
corrections and hands out the permanent IDs; clients download the result:

```sh
python3 -m library.cli sync
```

What is kept here, and why:

| file | what it is now |
|---|---|
| `canon.jsonl` | the ID registry as it stood on 2026-08-05. It is the **offline seed**: a fresh checkout with no network still gets the whole ID space from it (`canon.ensure_imported`). Not appended to any more — the server mints IDs. |
| `compat.jsonl` | verdicts as they stood on 2026-08-05. Read **only until the first sync**; after that `<games>/cache/compat/compat.jsonl` (the synced copy) is used instead, and reading both would show every verdict twice. |
| `patches.jsonl` | the corrections as they stood on 2026-08-05, still applied locally on every catalog open. The live copies are `Patch` rows on the server. |
| `compat-local.jsonl` | **yours**, gitignored, not frozen — this is where a verdict you record goes until `compat share` sends it. |

Do not add lines to the first three by hand. A verdict recorded in the app
lands in `compat-local.jsonl` and is sent with `compat share`; a correction
goes into the admin on fpgago.com, where a re-scrape cannot undo it.

Everything here is metadata only — titles, years, groups, source URLs,
content hashes. No game content has ever been committed to this repository
and none should be.
