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


def scrub(text, seed=386):
    """`text` with every word and digit swapped and every link pointed at
    example.com; markdown, dates, weekdays and times stay, so the shape and
    the due chips are the real file's and no word of it is."""
    rng = random.Random(seed)
    kept = []

    def hold(m):
        kept.append(m.group())
        return chr(
            0xE000 + len(kept) - 1
        )  # a private-use mark: no letter or digit to swap

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
    text = re.sub(r"^#+ .*$", lambda m: hold(m), text, flags=re.M)
    text = re.sub(r"^\s*\d+[.)](?=\s)", lambda m: hold(m), text, flags=re.M)

    def word(m):
        w = rng.choice(WORDS)
        return w.capitalize() if m.group()[0].isupper() else w

    text = re.sub(r"[^\W\d_]+", word, text)
    text = re.sub(r"\d", lambda _: str(rng.randrange(10)), text)
    for _ in range(2):  # a held heading holds its held dates
        text = re.sub("[\ue000-\uf8ff]", lambda m: kept[ord(m.group()) - 0xE000], text)
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
