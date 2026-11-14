# searxng-text: the character rules of the review file (./searxng-diff.sh).
#
#   esc code|data <IN >OUT   the text as the review file shows it
#   scan code|data FILE      `line <n>: <what>` for FILE's first line the
#                            review cannot see as it is; nothing if none
#   mask COUNT <IN >OUT      package-lock.json integrity lines masked;
#                            their number written to COUNT
#
# Lines are split at \n only (a CR, U+0085 or U+2028 is a character of
# its line, never a break). Every rule says what is held back (the
# nightly bump holds the update) and how the review file shows it.
#
# Both modes: a byte that is not UTF-8, a C0 control but TAB (ESC, CR, NUL
# included) and DEL are written `\xNN` and held back (the reviewer's file
# tool strips OSC sequences and refuses NUL and invalid UTF-8); so is
# `__HERMES_FENCE_` (written `__HERMES\x5fFENCE_`), a marker that tool
# strips.
#
# code (everything counted, the review's subject): printable ASCII and
# TAB pass. Any other character is held back, except one that is
#   - in a general category L*, M*, N*, P* or S* (letters, marks, digits,
#     punctuation, symbols: a visible glyph; never C*, Z*: controls,
#     format characters, private use, unassigned, separators, spaces),
#   - unchanged by NFKC (no fullwidth or compatibility lookalike of an
#     ASCII character: U+FF41, U+2024, U+2026, U+00B5, ...),
#   - not Default_Ignorable_Code_Point (Unicode's DerivedCoreProperties,
#     the table the nix build passes in: tag characters, variation
#     selectors, Hangul fillers, U+00AD, U+034F, ... including those a
#     category alone would let through, e.g. the Hangul filler U+3164 Lo),
#   - and not of bidi class R, AL or AN (Hebrew, Arabic letters and
#     digits reorder the neutral text around them on screen, no control
#     character needed).
# Such a character is written followed by its code point (a combining
# acute after an e as `e<U+0301>\u{0301}`): a homoglyph (a Cyrillic a in
# an identifier) is spelled out on the line it hides in, and the review
# brief (SKILL.md 2b) asks about every one. A held one is written
# `\u{XXXX}` alone. P* and S* are allowed beside L*/M*/N* because
# ASCII-or-L/M/N held the same 7 of 14 steps as ASCII alone. Measured against
# SearXNG master's weekly steps (Aug-Nov 2026): these rules hold 2 of 14
# steps (U+FE0F in a .md, U+2026 in a .py), plain ASCII-only would hold 7
# (U+2713/2715 in the themes' .min.css; U+2019, U+00B7, U+00D7, U+2190,
# U+2192, U+00F3, U+5409 in .py/.ts comments and strings).
#
# data (searx/data's diff, the other uncounted diff, the review file's own
# notes; engine names and translations are legitimately non-ASCII): only
# the bytes above are held back. Characters that are invisible or
# misleading on screen are written `\u{XXXX}` (not held): every
# Default_Ignorable_Code_Point (the table again), categories Cc, Cf, Co,
# Cs, Cn, Zl, Zp, Zs but U+0020, and the explicit set below (all of them
# default-ignorable today; listed so that a table change can never drop
# them). A ZWNJ in a Persian name stays readable as `\u{200C}`.
import re
import sys
import unicodedata

UCD = "@ucdDerived@"
# always written \u{XXXX} in data, held in code (see above)
ALWAYS = {0x00AD, 0x034F, 0x115F, 0x1160, 0x180E, 0x3164, *range(0x2061, 0x2065),
          *range(0xFE00, 0xFE10), *range(0xE0000, 0xE0080)}
SEP = {0x2028: "a line separator U+2028 (a line break to JavaScript, not to the diff)",
       0x2029: "a paragraph separator U+2029 (a line break to JavaScript, not to the diff)"}
BIDI = {0x061C, 0x200E, 0x200F, *range(0x202A, 0x202F), *range(0x2066, 0x206A)}
FENCE = "__HERMES_FENCE_"


def ignorables():
    di = set()
    with open(UCD, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0]
            if ";" not in line:
                continue
            rng, prop = (x.strip() for x in line.split(";", 1))
            if prop != "Default_Ignorable_Code_Point":
                continue
            a, _, b = rng.partition("..")
            di.update(range(int(a, 16), int(b or a, 16) + 1))
    if len(di) < 4000:  # 4174 in Unicode 17: a broken table must not pass
        raise SystemExit(f"searxng-text: {UCD}: only {len(di)} default-ignorables")
    return di | ALWAYS


DI = ignorables()


def code_ok(c):
    o = ord(c)
    return (unicodedata.category(c)[0] in "LMNPS" and o not in DI
            and unicodedata.normalize("NFKC", c) == c
            and unicodedata.bidirectional(c) not in ("R", "AL", "AN"))


def data_hidden(c):
    o = ord(c)
    cat = unicodedata.category(c)
    return o in DI or cat in ("Cc", "Cf", "Co", "Cs", "Cn", "Zl", "Zp") or (cat == "Zs" and o != 0x20)


def line_out(line, mode):
    """(shown text, first hold reason or None) of one line (str with
    surrogateescape for bytes that are not UTF-8)."""
    o = []
    why = None
    for c in line:
        n = ord(c)
        if c == "\t" or 0x20 <= n <= 0x7E:
            o.append(c)
            continue
        if 0xDC80 <= n <= 0xDCFF:  # surrogateescape: a byte that is not UTF-8
            o.append(f"\\x{n - 0xDC00:02x}")
            why = why or "invalid UTF-8 (\\x%02x)" % (n - 0xDC00)
            continue
        if n < 0x20 or n == 0x7F:
            o.append(f"\\x{n:02x}")
            why = why or ("an escape sequence (ESC, 0x1b)" if n == 0x1B
                          else "a DEL byte (0x7f)" if n == 0x7F else f"a control byte 0x{n:02x}")
            continue
        u = f"\\u{{{n:04X}}}"
        if mode == "code":
            if code_ok(c):
                o.append(c + u)
                continue
            o.append(u)
            if why is None:
                if n in SEP:
                    why = SEP[n]
                elif n in BIDI:
                    why = f"a bidi control U+{n:04X} (reorders what the review reads)"
                else:
                    cat = unicodedata.category(c)
                    what = ("default-ignorable (invisible)" if n in DI
                            else "NFKC changes it (a lookalike)" if unicodedata.normalize("NFKC", c) != c and cat[0] in "LMNPS"
                            else "right-to-left (reorders the text around it)" if cat[0] in "LMNPS"
                            else "not a visible glyph")
                    why = f"a non-ASCII character U+{n:04X} ({cat}, {what})"
        else:
            o.append(u if data_hidden(c) else c)
    s = "".join(o)
    if FENCE in line:
        why = why or "a terminal fence marker (__HERMES" "_FENCE_)"
    return s.replace(FENCE, "__HERMES\\x5fFENCE_"), why


def lines(data):
    parts = data.split(b"\n")
    if parts and parts[-1] == b"":
        parts.pop()
    return [p.decode("utf-8", "surrogateescape") for p in parts]


def esc(mode):
    out = sys.stdout.buffer
    for line in lines(sys.stdin.buffer.read()):
        s, _ = line_out(line, mode)
        out.write(s.encode("utf-8") + b"\n")


def scan(mode, path):
    with open(path, "rb") as f:
        for n, line in enumerate(lines(f.read()), 1):
            _, why = line_out(line, mode)
            if why:
                print(f"line {n}: {why}")
                return


# Exactly this, in a hunk of a package-lock.json diff, nothing else:
# npm's integrity hashes look like tokens to hermes' secret redactor.
# Any other line the redactor would change, in any section, holds the
# update back (./searxng-readcheck.py).
# (`[ \t]*`, not `\s*`: no CR or form feed inside the match)
INTEGRITY = re.compile(rb'^([ +-][ \t]*)"integrity": "(sha(?:256|384|512))-([A-Za-z0-9+/]+=*)"(,?)$')


def mask(count_file):
    n = 0
    lock = hunk = False
    out = sys.stdout.buffer
    data = sys.stdin.buffer.read()
    rows = data.split(b"\n")
    for i, line in enumerate(rows):
        if line.startswith(b"diff --git "):
            # git's header of a file whose path ends in /package-lock.json
            lock = line.endswith(b"/package-lock.json")
            hunk = False
        elif lock and line.startswith(b"@@ "):
            hunk = True
        elif lock and hunk and (m := INTEGRITY.match(line)):
            rows[i] = b'%s"integrity": "%s-(masked, %d characters)"%s' % (
                m.group(1), m.group(2), len(m.group(3)), m.group(4))
            n += 1
    out.write(b"\n".join(rows))
    with open(count_file, "w") as f:
        f.write(f"{n}\n")


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "esc" and a[1] in ("code", "data"):
        esc(a[1])
    elif len(a) == 3 and a[0] == "scan" and a[1] in ("code", "data"):
        scan(a[1], a[2])
    elif len(a) == 2 and a[0] == "mask":
        mask(a[1])
    else:
        sys.exit("usage: searxng-text esc code|data | scan code|data FILE | mask COUNT")
