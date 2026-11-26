"""Tests for scripts/needs_scrub.py: no word of the real file survives.

Run: python3 -I scripts/test_needs_scrub.py
"""

import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from needs_scrub import scrub  # noqa: E402

failures = 0


def check(name, ok, got=None):
    global failures
    print(f"{'ok  ' if ok else 'FAIL'} {name}" + ("" if ok else f"\n  got: {got!r}"))
    failures += not ok


SECRET = [
    "Reznik",
    "Zoë",
    "Ångström",
    "Müller",
    "privatething",
    "ajbarea",
    "secretrepo",
]
FILE = """# Needs you: Reznik's list

## Today (Wed 11-26)
- 📋 **Email Reznik:** about [secretrepo#12](https://github.com/ajbarea/secretrepo/issues/12) by 14:30
  - 📋 nested step for Zoë at https://example.org/privatething
### Ångström subgroup
#### Müller deep heading
1. ⏸ numbered item 2026-12-01
"""


def main():
    out = scrub(FILE)
    for word in SECRET:
        check(f"{word} is gone", word.lower() not in out.lower(), out)
    check(
        "no link but example.com",
        all(
            u.startswith("https://example.com/")
            for u in re.findall(r"https?://\S+?(?=[)\s]|$)", out)
        ),
        out,
    )
    check(
        "dates, weekdays and times stay",
        all(t in out for t in ["11-26", "Wed", "14:30", "2026-12-01"]),
        out,
    )
    check(
        "shape stays: one line per line",
        len(out.split("\n")) == len(FILE.split("\n")),
        out,
    )
    check(
        "headings keep their level",
        [ln.split(" ")[0] for ln in out.split("\n") if ln.startswith("#")]
        == ["#", "##", "###", "####"],
        out,
    )
    check(
        "list markers and emoji stay",
        "- 📋 **" in out and "  - 📋" in out and "1. ⏸" in out,
        out,
    )
    check("the same seed gives the same text", scrub(FILE) == out)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
