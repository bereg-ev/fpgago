"""Shared safety net for the library tests.

The committed databases — the compat database and the canon registry — live
at fixed paths inside the repo, and the app writes to them.  A test that
forgets to redirect one therefore does not fail: it quietly appends to the
real file, which is exactly the kind of bug that is only noticed later, in a
diff.  (It happened: `send to board` learned to assign a canon ID, and the
next test run published a fixture's fake "Pirates" release into the registry
everyone shares.)  So redirection is automatic here, and a test that wants
the real files has to say so by passing an explicit path.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))

import pytest  # noqa: E402

from library import canon, compat, patches  # noqa: E402


@pytest.fixture(autouse=True)
def _isolate_committed_data(tmp_path, monkeypatch):
    """Every repo path the library reads or writes, redirected.  All five of
    them — adding a sixth without adding it here is how a test starts quietly
    editing the user's data again, or quietly depending on a correction
    somebody added to the shipped patch file."""
    for name, fname in (("default_path", "compat.jsonl"),
                        ("local_path", "compat-local.jsonl"),
                        ("online_path", "compat-online.jsonl")):
        monkeypatch.setattr(compat, name,
                            lambda f=str(tmp_path / fname): f)
    monkeypatch.setattr(canon, "default_path",
                        lambda f=str(tmp_path / "canon.jsonl"): f)
    monkeypatch.setattr(patches, "default_path",
                        lambda f=str(tmp_path / "patches.jsonl"): f)
    return tmp_path
