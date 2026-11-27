"""Scrub a Needs you file for screenshots and fixtures: every word, digit and
link replaced, the markdown shape, dates, weekdays and times kept (#386).

    python3 -I scripts/needs_scrub.py FILE > scrubbed.md
"""

import random
import re
import sys

WORDS = "alpha bravo cedar delta ember fable grove harbor island jasper kettle lumen meadow north orbit pine quartz river stone tide".split()
DATE = re.compile(
    r"\b(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\b|\b\d{1,2}-\d{1,2}\b|\b\d{4}-\d{2}-\d{2}\b|\b\d{1,2}:\d{2}\b"
)


PRIVATE = "[\ue000-\uf8ff\U000f0000-\U000ffffd\U00100000-\U0010fffd]"
MARK = 0xF0000
MARKS = 0xFFFFD - MARK + 1


def scrub(text, seed=386):
    """`text` with every word and digit swapped and every link pointed at
    example.com; markdown, dates, weekdays and times stay, so the shape and
    the due chips are the real file's and no word of it is."""
    rng = random.Random(seed)
    kept = []
    # Marks are plane-15 private-use characters (no letter or digit to swap);
    # any private-use character already in the file (an icon) is dropped first.
    text = re.sub(PRIVATE, "?", text)

    def hold(m):
        kept.append(m.group())
        if len(kept) > MARKS:
            raise ValueError(f"more than {MARKS} dates, links and headings to hold")
        return chr(MARK + len(kept) - 1)

    text = re.sub(
        r"\]\([^)]*\)",
        lambda m: "](" + hold(re.match(r".*", "https://example.com/item")) + ")",
        text,
    )
    text = re.sub(
        r"https?://\S+",
        lambda m: hold(re.match(r".*", "https://example.com/item")),
        text,
    )
    text = DATE.sub(hold, text)
    text = re.sub(r"^#{1,6} .*$", lambda m: hold(m), text, flags=re.M)
    text = re.sub(r"^\s*\d+[.)](?=\s)", lambda m: hold(m), text, flags=re.M)

    def word(m):
        w = rng.choice(WORDS)
        return w.capitalize() if m.group()[0].isupper() else w

    text = re.sub(r"[^\W\d_]+", word, text)
    text = re.sub(r"\d", lambda _: str(rng.randrange(10)), text)
    for _ in range(2):  # a held heading holds its held dates
        text = re.sub(PRIVATE, lambda m: kept[ord(m.group()) - MARK], text)
    # Section titles are the file's own words: placeholders keep the order, dates stay.
    titles = iter(["## Today", "## Coming up", "## When convenient", "## Later"])
    out = []
    for line in text.split("\n"):
        level = re.match(r"#{2,6} ", line)
        if level:
            date = re.search(r" \(.*\)$", line)
            line = (
                "#" * (len(level.group()) - 1)
                + next(titles, "## More")[2:]
                + (
                    " (" + " ".join(DATE.findall(date.group())) + ")"
                    if date and DATE.search(date.group())
                    else ""
                )
            )
        elif line.startswith("# "):
            line = "# Needs you"
        out.append(line)
    return "\n".join(out)


if __name__ == "__main__":
    sys.stdout.write(scrub(open(sys.argv[1], encoding="utf-8").read()))
