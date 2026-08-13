"""library/share.py — getting a user's test results back to the project.

The compatibility database is a git-tracked JSONL file, which is a fine way
for the project to *store* verdicts and a hopeless way for most people to
*send* them: "fork the repo, commit a line, open a pull request" is not a
thing someone who just wanted to play Pirates! is going to do.

So the app keeps the user's own reports in a local file
(`compat.local_path()`) and offers three ways out, in descending order of
"it just happens":

  1. **`gh` CLI** — if GitHub's own CLI is installed and logged in, the app
     opens the issue directly.  One click, no browser.
  2. **A pre-filled issue in the browser** — a GitHub account is still
     needed, but nothing else: the title and the body arrive filled in, and
     the user presses Submit.
  3. **The text** — copy it, or save it to a file, and send it however.
     Forum, email, carrier pigeon.

Everything here is stdlib + an optional subprocess; nothing imports Qt, so
the routes are testable without a GUI and usable from the CLI.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import urllib.parse
from typing import Optional

from . import compat

# Where reports go when nothing better is known.  Overridden by the repo's
# own `origin` remote when the app is running from a checkout.
DEFAULT_SLUG = "bereg-ev/fpgago"
ISSUE_LABEL = "compat-report"


def repo_slug() -> str:
    """`owner/repo` for the project — from git if we are in a checkout."""
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        url = subprocess.run(
            ["git", "-C", here, "remote", "get-url", "origin"],
            capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:                                # noqa: BLE001
        url = ""
    return slug_from_url(url) or DEFAULT_SLUG


def slug_from_url(url: str) -> Optional[str]:
    """git@github.com:owner/repo.git / https://github.com/owner/repo →
    owner/repo.  Anything else (a fork on another host, a local path) →
    None, so we fall back to the project's own repo."""
    if not url or "github.com" not in url:
        return None
    tail = url.split("github.com", 1)[1].lstrip(":/")
    if tail.endswith(".git"):
        tail = tail[:-4]
    parts = [p for p in tail.split("/") if p]
    return "/".join(parts[:2]) if len(parts) >= 2 else None


def summary(reports) -> str:
    """One line per report, the way a human reads it."""
    return "\n".join(f"* {r['id']} on {r['machine']}: {r['status']}"
                     + ("  [needs the real 1541]" if r.get("real1541") else "")
                     + (f" — {r['notes']}" if r.get("notes") else "")
                     + ("  [has settings]" if r.get("profile") else "")
                     for r in reports)


def issue_title(reports) -> str:
    if len(reports) == 1:
        r = reports[0]
        return f"compat: {r['id']} on {r['machine']} — {r['status']}"
    return f"compat: {len(reports)} test results"


def issue_body(reports) -> str:
    return (
        "Test results from the fpgago desktop app.\n\n"
        + summary(reports)
        + "\n\nFor the database (`desktop/library/data/compat.jsonl`):\n\n"
        "```jsonl\n" + compat.report_lines(reports) + "\n```\n")


def issue_url(reports, slug: Optional[str] = None) -> str:
    """A GitHub 'new issue' URL with everything filled in."""
    q = urllib.parse.urlencode({"title": issue_title(reports),
                                "body": issue_body(reports),
                                "labels": ISSUE_LABEL})
    return f"https://github.com/{slug or repo_slug()}/issues/new?{q}"


def have_gh() -> bool:
    """Is GitHub's CLI installed *and* logged in?  Installed-but-anonymous
    would fail at submit time, which is a worse experience than not offering
    the button at all."""
    if not shutil.which("gh"):
        return False
    try:
        return subprocess.run(["gh", "auth", "status"], capture_output=True,
                              timeout=10).returncode == 0
    except Exception:                                # noqa: BLE001
        return False


def submit_with_gh(reports, slug: Optional[str] = None) -> str:
    """Create the issue with `gh`.  Returns its URL; raises on failure."""
    cmd = ["gh", "issue", "create",
           "--repo", slug or repo_slug(),
           "--title", issue_title(reports),
           "--body", issue_body(reports)]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        # A missing label is the one failure worth retrying automatically:
        # a fresh fork has no `compat-report` label and gh refuses the whole
        # issue over it.
        raise IOError((r.stderr or r.stdout).strip() or "gh issue create failed")
    url = (r.stdout or "").strip().splitlines()[-1:]
    return url[0] if url else ""


def export(reports, path: str) -> str:
    """Write the reports as JSONL to `path`; returns the path."""
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(compat.report_lines(reports) + "\n")
    return path


def routes(reports) -> list[dict]:
    """The ways this user could send `reports`, best first.  A dict per
    route so a GUI can render buttons without knowing what exists."""
    out = []
    # The direct route, when this machine is signed in: no git, no GitHub
    # account, no maintainer copying lines out of an issue by hand.
    who = _account()
    if who:
        out.append({"key": "web", "label": "Send to fpgago.com",
                    "hint": f"signed in as {who} — goes straight into the "
                            f"database everyone syncs"})
    if have_gh():
        out.append({"key": "gh", "label": "Send now (GitHub CLI)",
                    "hint": "gh is installed and logged in — one click"})
    out.append({"key": "browser", "label": "Open a pre-filled report…",
                "hint": "opens GitHub in your browser with everything "
                        "already written; you press Submit"})
    out.append({"key": "copy", "label": "Copy to clipboard",
                "hint": "paste it into a forum post, an issue or an email"})
    out.append({"key": "file", "label": "Save to a file…",
                "hint": "send it however you like"})
    return out


def _account() -> Optional[str]:
    """The signed-in username, or None.  Never raises and never blocks for
    long: this is called to decide what a dialog should offer, and being
    offline must not stop the other routes being shown."""
    try:
        from . import webapi
        if not webapi.logged_in():
            return None
        who = webapi.whoami()
        return who.get("user") if who else None
    except Exception:                                # noqa: BLE001
        return None


def submit_to_web(reports) -> dict:
    """Send the reports to fpgago.com.  Returns the server's answer:
    {"accepted": n, "rejected": [{"index", "error"}]}."""
    from . import webapi
    return webapi.submit_reports(reports)


def preview(reports) -> str:
    """What the user is about to send, as plain text."""
    return issue_title(reports) + "\n\n" + issue_body(reports)


def as_json(reports) -> str:
    return json.dumps([{k: v for k, v in r.items() if not k.startswith("_")}
                       for r in reports], indent=2)
