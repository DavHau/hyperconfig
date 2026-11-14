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
#   - not changed by NFKC if it can be part of an identifier
#     (XID_Continue: Python folds identifiers by NFKC, so a fullwidth
#     U+FF41 or U+00B5 IS another name); an NFKC-changed character that
#     is no identifier character (U+2026, U+2024, U+FF0F) passes,
#     annotated (in a string or comment the review reads it as itself),
#   - not Default_Ignorable_Code_Point (Unicode's DerivedCoreProperties,
#     the table the nix build passes in: tag characters, variation
#     selectors, Hangul fillers, U+00AD, U+034F, ... including those a
#     category alone would let through, e.g. the Hangul filler U+3164 Lo),
#   - and not of bidi class R, AL or AN (Hebrew, Arabic letters and
#     digits reorder the neutral text around them on screen, no control
#     character needed).
# A word (a run of XID_Continue characters) that mixes scripts (Scripts.txt
# of the same UCD; Common and Inherited do not count; Latin with Han and
# Hiragana/Katakana, Bopomofo or Hangul is allowed, UTS 39's highly
# restrictive level) holds too: `b\u0430se_url` (a Cyrillic a in a Latin
# name) is another identifier that reads the same.
# Such a character is written followed by its code point (a combining
# acute after an e as `e<U+0301>\u{0301}`): a homoglyph (a Cyrillic a in
# a string) is spelled out on the line it hides in, and the review
# brief (SKILL.md 2b) asks about every one. A held one is written
# `\u{XXXX}` alone. Documentation in the code diff (a file ending .md or
# .rst, by git's header line; no code reads it) has the data rules below:
# an emoji's U+FE0F there is shown as `\u{FE0F}`, not held.
# Measured against SearXNG master's weekly steps (Aug-Nov 2026): plain
# ASCII-only would hold 7 of 14 steps, these rules none of them for
# characters (rv9 in the commit's measurement).
#
# data (the searx/data summary and diff, the other uncounted diff, .md and
# .rst in the code diff, the review file's own notes; engine names and
# translations are legitimately non-ASCII): only the bytes above are held
# back. Characters that are invisible, blank or misleading on screen are
# written `\u{XXXX}` (not held): every Default_Ignorable_Code_Point (the
# table again), categories Cc, Cf, Co, Cs, Cn, Zl, Zp, Zs but U+0020, the
# blank-looking glyphs (BLANK: U+2800 braille blank, U+FFA0, U+3164, ...)
# and the explicit set below (all of them default-ignorable today; listed
# so that a table change can never drop them). A ZWNJ in a Persian name
# stays readable as `\u{200C}`.
#
# Versions: categories, NFKC and bidi classes come from Python's
# unicodedata (Unicode 16 in python 3.14), DI, XID_Continue and scripts
# from nixpkgs' UCD (17). A character new in 17 is Cn to Python: held in
# code, escaped in data (fail closed); the assert below refuses a Python
# whose table is older than 15 or newer than the UCD.
#
# summary OLDDIR NEWDIR [full|hosts]: the searx/data JSON files' summary
# (./searxng-diff.sh). hosts (the raw diff fits the review file and is
# the review's view): per changed file its counts, the registrable
# domains new and gone (the public suffix list passed in) and the holds.
# full (the raw diff does not fit; this stands in for it): also every
# changed or added scalar by JSON path, old -> new, in every file but
# the two display-only ones (DISPLAY_ONLY below: counts, URL and
# structure checks only), whatever its size or name (no guess at which
# values name a host);
# removed values are counted only. A URL candidate is shown with its
# host. Every non-ASCII character is annotated `\u{XXXX}` (a Cyrillic o
# in gooоgle.com reads `goo\u{043E}gle.com`). Held, in both modes: a
# new or changed URL candidate that is not exactly http(s):// + a plain
# host[:port] (the rules and the real data's exceptions at NOT_URL
# below); a bare host with userinfo; a new host whose letters mix
# scripts in a label (also after punycode); a file that is not JSON.
import json
import re
import sys
import unicodedata
import urllib.parse

UCD = "@ucdDerived@"
SCRIPTS = "@ucdScripts@"
PSL = "@publicSuffixList@"
# always written \u{XXXX} in data, held in code (see above)
ALWAYS = {0x00AD, 0x034F, 0x115F, 0x1160, 0x180E, 0x3164, *range(0x2061, 0x2065),
          *range(0xFE00, 0xFE10), *range(0xE0000, 0xE0080)}
# glyphs that render blank (not default-ignorable, not Z*): written
# \u{XXXX} in data; in code most are held by the rules anyway
BLANK = {0x2800, 0xFFA0, 0x3164, 0x115F, 0x1160, 0x2063, 0x31F, 0x1D159, 0x1D173,
         *range(0x1D174, 0x1D17B), 0x2062, 0x2064, 0x205F, 0x17B4, 0x17B5}
SEP = {0x2028: "a line separator U+2028 (a line break to JavaScript, not to the diff)",
       0x2029: "a paragraph separator U+2029 (a line break to JavaScript, not to the diff)"}
BIDI = {0x061C, 0x200E, 0x200F, *range(0x202A, 0x202F), *range(0x2066, 0x206A)}
FENCE = "__HERMES_FENCE_"
# Python's own table must not be older than 15 nor newer than the UCD's
# (a newer one would call characters assigned that the UCD files lack)
_pv = tuple(int(x) for x in unicodedata.unidata_version.split(".")[:2])
assert (15, 0) <= _pv <= (17, 0), f"unicodedata {unicodedata.unidata_version}"


def ucd_ranges(path, want=None):
    """{codepoint: value} of a UCD property file (`a..b ; value # ...`)."""
    out = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0]
            if ";" not in line:
                continue
            rng, prop = (x.strip() for x in line.split(";", 1))
            if want is not None and prop != want:
                continue
            a, _, b = rng.partition("..")
            for c in range(int(a, 16), int(b or a, 16) + 1):
                out[c] = prop
    return out


def ignorables():
    di = set(ucd_ranges(UCD, "Default_Ignorable_Code_Point"))
    if len(di) < 4000:  # 4174 in Unicode 17: a broken table must not pass
        raise SystemExit(f"searxng-text: {UCD}: only {len(di)} default-ignorables")
    return di | ALWAYS


DI = ignorables()
XIDC = set(ucd_ranges(UCD, "XID_Continue"))
if len(XIDC) < 100000:  # 140k+ in Unicode 17
    raise SystemExit(f"searxng-text: {UCD}: only {len(XIDC)} XID_Continue")
SCRIPT = ucd_ranges(SCRIPTS)
if len(SCRIPT) < 100000:
    raise SystemExit(f"searxng-text: {SCRIPTS}: only {len(SCRIPT)} characters with a script")
# UTS 39 highly restrictive: Latin may go with these CJK sets
CJK_OK = [{"Latin", "Han", "Hiragana", "Katakana"}, {"Latin", "Han", "Bopomofo"},
          {"Latin", "Han", "Hangul"}]


def scripts_of(word):
    return {SCRIPT.get(ord(c), "Unknown") for c in word} - {"Common", "Inherited"}


def mixed(word):
    s = scripts_of(word)
    return len(s) > 1 and not any(s <= ok for ok in CJK_OK)


def code_why(c):
    """None if c may stand in code (shown annotated), else what it is."""
    o = ord(c)
    cat = unicodedata.category(c)
    if cat[0] not in "LMNPS":
        return "not a visible glyph"
    if o in DI:
        return "default-ignorable (invisible)"
    if o in BLANK:
        return "a blank glyph (reads as a space)"
    if unicodedata.bidirectional(c) in ("R", "AL", "AN"):
        return "right-to-left (reorders the text around it)"
    if o in XIDC and unicodedata.normalize("NFKC", c) != c:
        return "an identifier character NFKC changes (a lookalike name)"
    return None


def data_hidden(c):
    o = ord(c)
    cat = unicodedata.category(c)
    return (o in DI or o in BLANK or cat in ("Cc", "Cf", "Co", "Cs", "Cn", "Zl", "Zp")
            or (cat == "Zs" and o != 0x20))


WORD = re.compile(r"\w+")


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
            w = code_why(c)
            if w is None:
                o.append(c + u)
                continue
            o.append(u)
            if why is None:
                if n in SEP:
                    why = SEP[n]
                elif n in BIDI:
                    why = f"a bidi control U+{n:04X} (reorders what the review reads)"
                else:
                    why = f"a non-ASCII character U+{n:04X} ({unicodedata.category(c)}, {w})"
        else:
            o.append(u if data_hidden(c) else c)
    if mode == "code" and why is None and not line.isascii():
        for m in WORD.finditer(line):
            wd = m.group(0)
            if not wd.isascii() and mixed(wd):
                why = (f"a word mixing scripts ({', '.join(sorted(scripts_of(wd)))}): "
                       "it reads like another name")
                break
    s = "".join(o)
    if FENCE in line:
        why = why or "a terminal fence marker (__HERMES" "_FENCE_)"
    return s.replace(FENCE, "__HERMES\\x5fFENCE_"), why


def doc_path(line):
    """For a `diff --git a/old/X b/new/Y` line: is it documentation?"""
    return line.startswith("diff --git ") and line.endswith((".md", ".rst"))


def lines(data):
    parts = data.split(b"\n")
    if parts and parts[-1] == b"":
        parts.pop()
    return [p.decode("utf-8", "surrogateescape") for p in parts]


def modes(rows, mode):
    """(line, its mode): in code, a .md/.rst file's diff has data rules."""
    cur = mode
    for line in rows:
        if mode == "code" and line.startswith("diff --git "):
            cur = "data" if doc_path(line) else "code"
        yield line, cur


def esc(mode):
    out = sys.stdout.buffer
    for line, m in modes(lines(sys.stdin.buffer.read()), mode):
        s, _ = line_out(line, m)
        out.write(s.encode("utf-8") + b"\n")


def scan(mode, path):
    with open(path, "rb") as f:
        for n, (line, m) in enumerate(modes(lines(f.read()), mode), 1):
            _, why = line_out(line, m)
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


# -- the searx/data summary ------------------------------------------

# URL candidates: a string that, after any leading C0 controls and
# spaces, starts with a scheme (`[A-Za-z][A-Za-z0-9+.-]*:`) or with two
# of `/` and `\` (browsers read `\` as `/`). A candidate holds unless it
# is exactly `http://` or `https://` (scheme case folded) + a valid
# authority (ASCII host labels, letters, digits and inner hyphens, at
# least one dot, an optional :port) ending at `/`, `?`, `#` or the end,
# with no leading blank or control and no control or invisible character
# anywhere after it. So `https:\\x`, `https:/x`, `https:x`, `javascript:`,
# `data:`, `//x` outside external_bangs.json, userinfo, IPv6, `%` or a
# non-ASCII host all hold. Exceptions, each one a form that occurs in
# SearXNG's own data (all searx/data JSON files of 19 upstream revisions,
# Aug-Nov 2026; nothing else matched):
#   - external_bangs.json: `//` + a valid authority (scheme-relative,
#     ~180k bangs); `\x02` (the query's place: anywhere, also as a host
#     label) and a trailing `\x01<digits>` (the bang's rank);
#   - engine_descriptions.json: at /<lang>/<engine>[0] a reference
#     `<engine>:<lang>` (`bing:af`); at /<lang>/<engine> prose of three
#     words or more, the first letters, a colon, letters
#     (`Modelo:Dominio Wikilibros é ...`);
#   - engine_traits.json: /google news/custom/ceid/* `AE:ar`
#     (`[A-Z]{2}:<lang>`), /arch linux wiki/custom/title/* `Spezial:Suche`
#     (`<letters>:<letters>`);
#   - osm_keys_tags.json: /tags/... or /keys/... labels of letter words,
#     a colon in the first (`wlan:in saatavuus`).
# None of them applies to a string starting with `http` (any case).
LEAD = "".join(map(chr, range(0x21)))
SCHEME = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*:")
SLASH2 = re.compile(r"[/\\]{2}")
LABEL = r"(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)"
BLABEL = r"(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?|\x02)"
AUTH = re.compile(rf"{LABEL}(?:\.{LABEL})+(?::[0-9]{{1,5}})?(?=[/?#]|\Z)")
BAUTH = re.compile(rf"{BLABEL}(?:\.{BLABEL})+(?::[0-9]{{1,5}})?(?=[/?#]|\Z)")
BANG_TAIL = re.compile(r"\x01[0-9]+\Z")
BANGS = "external_bangs.json"
LANG = r"[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*"
NOT_URL = {  # (file, path regex, value regex): the real data's forms
    "engine_descriptions.json": [
        (re.compile(r"/[^/]+/[^/]+\[0\]"), re.compile(rf"[a-z0-9][a-z0-9 ._-]*:{LANG}")),
        # a plain description string only, never a [0]/[1] slot
        (re.compile(r"/[^/\[\]]+/[^/\[\]]+"), re.compile(r"[^\W\d_]+:[^\W\d_]+(?:\s+\S+){2,}", re.S)),
    ],
    "engine_traits.json": [
        (re.compile(r"/google news/custom/ceid/[^/]+"), re.compile(rf"[A-Z]{{2}}:{LANG}")),
        (re.compile(r"/arch linux wiki/custom/title/[^/]+"), re.compile(r"[^\W\d_]+:[^\W\d_]+")),
    ],
    "osm_keys_tags.json": [
        (re.compile(r"/(?:tags|keys)/.+"), re.compile(r"[^\W\d_]+:[^\W\d_]+(?:\s+[^\W\d_]+)+")),
    ],
}
# inside prose (engine descriptions): a URL token, up to white space
URL_IN = re.compile(r"(?:\b[A-Za-z][A-Za-z0-9+.-]*:)?//\S+")
# a string that is a host name and nothing else (engine_traits'
# supported_domains: `www.google.at`); unicode letters included
HOSTNAME = re.compile(r"[\w-]+(?:\.[\w-]+)+\.?")
# host-like in the wider sense (a netloc: `evil.com:443`, `10.0.0.5`,
# `a@b.c`, `[::1]:80`): no white space, a dot, colon or @ in it
HOSTISH = re.compile(r"[\w.\[\]:@-]+")


def psl():
    rules, exc, wild = set(), set(), set()
    with open(PSL, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            line = line.split()[0]
            if line.startswith("!"):
                exc.add(line[1:])
            elif line.startswith("*."):
                wild.add(line[2:])
            else:
                rules.add(line)
    if len(rules) < 5000:
        raise SystemExit(f"searxng-text: {PSL}: only {len(rules)} public suffixes")
    return rules, exc, wild


_PSL = None


def registrable(host):
    """The registrable domain of host (the public suffix list's
    algorithm: longest matching rule, exceptions first, `*` by default),
    the host itself if it has none (an IP, a bare suffix, a template)."""
    global _PSL
    if _PSL is None:
        _PSL = psl()
    rules, exc, wild = _PSL
    h = host.lower().rstrip(".")
    if not h or h.startswith("[") or re.fullmatch(r"[0-9.]+", h):
        return h  # an IP address
    labels = h.split(".")
    n = len(labels)
    k = 1  # labels in the public suffix; the default rule `*`
    for i in range(n):  # longest suffix first
        suf = ".".join(labels[i:])
        if suf in exc:  # `!x.y.z`: the suffix is y.z
            k = n - i - 1
            break
        if suf in rules:
            k = n - i
            break
        if i + 1 < n and ".".join(labels[i + 1:]) in wild:  # `*.y.z`
            k = n - i
            break
    return ".".join(labels[n - k - 1:]) if n > k else h


def candidate(s):
    """Is s a URL candidate (see above)?"""
    t = s.lstrip(LEAD)
    return bool(SCHEME.match(t) or SLASH2.match(t))


def url_check(s, rel="", path=""):
    """For a URL candidate: (host, why): the host of its authority (or
    urllib.parse's, when it is not valid) and why it holds (None if it
    does not). (None, None) for a string that is no candidate, or one of
    the real data's non-URL forms at its place (NOT_URL)."""
    if not candidate(s):
        return None, None
    base = rel.rsplit("/", 1)[-1]
    bangs = base == BANGS
    if not s.lower().startswith("http"):  # an http(s) one is always checked
        for pr, vr in NOT_URL.get(base, ()):
            if pr.fullmatch(path) and vr.fullmatch(s):
                return None, None
    try:
        guess = urllib.parse.urlsplit(s.lstrip(LEAD)).hostname or ""
    except ValueError:
        guess = ""
    if s[:1] in LEAD:
        return guess, (f"a URL behind leading blanks or controls ({ascii(s[:12])}...): "
                       "a browser strips them, the review reads past them")
    body = BANG_TAIL.sub("", s) if bangs else s
    low = body[:8].lower()
    if low.startswith("https://"):
        rest = body[8:]
    elif low.startswith("http://"):
        rest = body[7:]
    elif bangs and body.startswith("//"):
        rest = body[2:]
    else:
        return guess, ("a URL that is not exactly http(s):// + a host"
                       + (" (or // + a host)" if bangs else "")
                       + f" ({ascii(body[:40])}): scheme or slashes another reader takes differently")
    m = (BAUTH if bangs else AUTH).match(rest)
    if not m:
        return guess, (f"a URL whose authority is no plain host[:port] ({ascii(rest[:60])}): "
                       "userinfo, a backslash, `%`, IPv6, a non-ASCII or dotless host read differently "
                       f"(urllib.parse: {ascii(guess)})")
    host = m.group(0).rsplit(":", 1)[0] if ":" in m.group(0) else m.group(0)
    check = body.replace("\x02", "") if bangs else body
    for ch in check:
        n = ord(ch)
        if n < 0x20 or n == 0x7F or (n != 0x20 and data_hidden(ch)):
            return host, (f"a URL with U+{n:04X} in it: the URL is not the whole string "
                          "(the review reads up to there, a browser further)")
    return host, None


def hosts_in(s, rel=""):
    """The hosts a string names (a URL candidate's host; each URL token
    in prose; a bare host or netloc as itself). Domains list only."""
    if candidate(s):
        h, _ = url_check(s, rel, "\x00")  # no NOT_URL exception: a host
        return {h} if h else set()
    out = set()
    for u in URL_IN.findall(s):
        try:
            h = urllib.parse.urlsplit(u.rstrip(".,;:)!?")).hostname
        except ValueError:
            h = None
        if h:
            out.add(h)
    if not out and hostish(s):
        try:
            h = urllib.parse.urlsplit("//" + s).hostname
        except ValueError:
            h = None
        if h:
            out.add(h)
    return out


def hostish(s):
    """A bare host or netloc beyond public-suffix names: `evil.com:443`,
    `10.0.0.5`, `[::1]:80`, `a.org@evil.com` (not a number or version)."""
    if not HOSTISH.fullmatch(s):
        return False
    if net(s) or "@" in s:
        return True
    try:
        sp = urllib.parse.urlsplit("//" + s)
        h, port = sp.hostname or "", sp.port
    except ValueError:
        return False
    if re.fullmatch(r"[0-9]{1,3}(?:\.[0-9]{1,3}){3}", h) or ":" in h:
        return True  # an IPv4 or IPv6 address
    return port is not None and bool(re.search(r"[^\W\d_]", h))


def host_letters_mixed(host):
    """Does host's text, or its punycode decoded, mix scripts per label?"""
    labels = host.split(".")
    for lb in labels:
        t = lb
        if lb.lower().startswith("xn--"):
            try:
                t = lb.encode("ascii").decode("idna")
            except UnicodeError:
                return True
        if mixed(t):
            return True
    return False


def netish(s):
    """Does the string name a host: a URL, a URL in prose, a bare host
    under a public suffix, a netloc?"""
    return bool(candidate(s) or URL_IN.search(s) or net(s) or hostish(s))


def net(t):
    """t itself when it is a host name under a public suffix, else ()."""
    if HOSTNAME.fullmatch(t) and not t.replace(".", "").isdigit():
        if _PSL is None:
            registrable("x")
        tld = t.rstrip(".").rsplit(".", 1)[-1].lower()
        if registrable(t) != t.lower().rstrip(".") or tld in _PSL[0]:
            return (t,)
    return ()


class Empty(str):
    """An empty object or list, as a scalar of flat() (never equal to a
    string: compared by kind and text)."""


EMPTY = {dict: Empty("{}"), list: Empty("[]")}


def same(x, y):
    return type(x) is type(y) and json.dumps(x) == json.dumps(y)


def seg(k):
    return f"/{k}" if re.fullmatch(r"[A-Za-z0-9_. -]*", k) else "/" + json.dumps(k, ensure_ascii=False)


def flat(x, path, out, keys, counts):
    """Every scalar (and empty container) of x by JSON path; keys: the
    dict keys by path (`<path> (key)`), counts: [keys, strings]."""
    if isinstance(x, dict):
        counts[0] += len(x)
        if not x:
            out[path] = EMPTY[dict]
        for k, v in x.items():
            p = path + seg(k)
            keys[p + " (key)"] = k
            flat(v, p, out, keys, counts)
    elif isinstance(x, list):
        if not x:
            out[path] = EMPTY[list]
        for i, v in enumerate(x):
            flat(v, f"{path}[{i}]", out, keys, counts)
    else:
        if isinstance(x, str):
            counts[1] += 1
        out[path] = x


def shown(v, rel):
    """A value as the summary shows it: JSON (controls as \\uXXXX), every
    non-ASCII character spelled out; a URL candidate with its host."""
    t = str(v) if isinstance(v, Empty) else json.dumps(v, ensure_ascii=False)
    s = ann(t)
    if isinstance(v, str) and candidate(v):
        h = next(iter(hosts_in(v, rel)), "")
        s += f"  [host {ann(h) if h else '(none)'}]"
    return s


def ann(t):
    """A string as the summary shows it: ASCII as is, every other
    character spelled out after it (`o\\u{043E}`), or alone when it is
    invisible or a control (data rules), so a homoglyph in a URL shows."""
    o = []
    for c in t:
        n = ord(c)
        if 0x20 <= n <= 0x7E:
            o.append(c)
        elif n < 0x20 or n == 0x7F or 0xD800 <= n <= 0xDFFF or data_hidden(c):
            o.append(f"\\u{{{n:04X}}}")
        else:
            o.append(f"{c}\\u{{{n:04X}}}")
    return "".join(o)


# Display-only data (Dave's decision; usage verified in SearXNG's source,
# Aug-Nov 2026): searx/data/engine_descriptions.json is read only by
# webapp.py's /engine_descriptions.json route (ENGINE_DESCRIPTIONS, the
# engine blurbs of the HTML preferences page: client preferences.ts sets
# them with innerHTML, "<text> (Source: <[1]>)"), and
# searx/data/wikidata_properties.json only by
# wikidata_properties.py:get_label_for_entity (WIKIDATA_PROPERTIES, the
# labels of the wikidata infobox, autoescaped by the template). Neither
# reaches a request, a host or code. For EXACTLY these two paths the
# summary shows no values, only counts (keys and strings added, changed,
# removed), so a translation refresh no longer fills the review file.
# Instead, held:
#   - any new or changed string (keys too) that is a URL candidate, with
#     the real data's forms excepted only where they do not start like a
#     URL: engine_descriptions' reference `<engine>:<lang>` at
#     /<lang>/<engine>[0] (`bing:af`, `currency:af`), its prose
#     `Modelo:Dominio ...` (NOT_URL above), and its source link at
#     /<lang>/<engine>[1] when that is a plain http(s)://host[:port] URL
#     (url_check clean; the `Source:` text; 71 of them changed in the
#     487f5192 step alone, so without it every description refresh
#     holds): DISPLAY_SOURCE below, one line to drop for the strict rule;
#   - `<` or `>` in a new or changed engine_descriptions string (the
#     innerHTML sink above; none in any measured revision); URLs inside
#     prose are plain text there (no `<a>` without `<`): their registrable
#     domains are listed, not held;
#   - a type structure change: engine_descriptions must stay a dict of
#     lang -> dict of engine -> str | [str, str], wikidata_properties a
#     dict of id -> str | dict of lang -> str. A code change that starts
#     reading these files elsewhere comes through the counted code diff;
#     the review brief (SKILL.md 2b) makes that a finding.
DISPLAY_ONLY = {"searx/data/engine_descriptions.json", "searx/data/wikidata_properties.json"}
DISPLAY_SOURCE = re.compile(r"/[^/]+/[^/]+\[1\]")


def display_shape(rel, j):
    """Why j is not the display-only file's type structure (None if it is)."""
    if not isinstance(j, dict):
        return f"the top level is {type(j).__name__}, not an object"
    for k, v in j.items():
        if rel.endswith("engine_descriptions.json"):
            if not isinstance(v, dict):
                return f"{ascii(k)} is {type(v).__name__}, not an object of engines"
            for e, d in v.items():
                if not (isinstance(d, str) or (isinstance(d, list) and len(d) == 2
                                               and all(isinstance(x, str) for x in d))):
                    return f"{ascii(k)}/{ascii(e)} is not a string or a [string, string]"
        elif not (isinstance(v, str) or (isinstance(v, dict) and all(isinstance(x, str) for x in v.values()))):
            return f"{ascii(k)} is not a string or an object of strings"
    return None


def display_only(rel, ea, eb, jb, fa, fb, kya, kyb, ca, cb, out, holds):
    """The summary of a display-only file: counts, URL and shape holds."""
    sa = {p: v for p, v in fa.items() if isinstance(v, str) and not isinstance(v, Empty)}
    sb = {p: v for p, v in fb.items() if isinstance(v, str) and not isinstance(v, Empty)}
    state = "new file" if not ea else "removed" if not eb else "changed"
    out.append(f"## {rel} ({state}; display-only: counts, URL and structure checks, no values): "
               f"keys {ca[0]} -> {cb[0]}, strings {ca[1]} -> {cb[1]}")
    out.append(f"  keys added {len(kyb.keys() - kya.keys())}, removed {len(kya.keys() - kyb.keys())}; "
               f"strings added {len(sb.keys() - sa.keys())}, "
               f"changed {sum(1 for p in sb.keys() & sa.keys() if sa[p] != sb[p])}, "
               f"removed {len(sa.keys() - sb.keys())}")
    if eb and (why := display_shape(rel, jb)):
        holds.append(f"{rel}: its structure changed ({why}): a display-only file must keep its shape")
    ed = rel.endswith("engine_descriptions.json")
    srcs, named = set(), set()
    for p, v in sorted((sb | kyb).items()):
        if (sa | kya).get(p) == v:
            continue
        named |= {registrable(h) for h in hosts_in(v, rel)} if URL_IN.search(v) and not candidate(v) else set()
        if ed and ("<" in v or ">" in v):
            holds.append(f"{rel}: {ascii(p)}: a `<` or `>` (the preferences page sets it as HTML)")
        if not candidate(v):
            continue
        host, why = url_check(v, rel, p)
        if host is None and why is None:
            continue  # the real data's non-URL forms (NOT_URL)
        if ed and why is None and DISPLAY_SOURCE.fullmatch(p):
            srcs.add(registrable(host))
            continue
        holds.append(f"{rel}: {ascii(p)}: a URL in a display-only file"
                     + (f" ({why})" if why else f" (host {ascii(host)})"))
    if srcs:
        out.append(f"  source links (`Source:` text) to {len(srcs)} registrable domains: "
                   + " ".join(ann(h) for h in sorted(srcs)))
    if named:
        out.append("  URLs inside new or changed prose (plain text on the page) name: "
                   + " ".join(ann(h) for h in sorted(named)))


def load(path):
    try:
        with open(path, "rb") as f:
            return json.loads(f.read().decode("utf-8")), None
    except (OSError, ValueError) as e:
        return None, type(e).__name__


def summary(old, new, mode="full"):
    """stdout: the summary (text, data rules applied by the caller's esc);
    exit 0. Holds go to stdout as `HOLD <reason>` lines at the very end
    (the caller moves them). mode full: per changed file every changed
    or added scalar (and empty container) by JSON path, old -> new, in
    every file whatever its size or name; removed ones counted only;
    mode hosts: per file only the header, the registrable domains new
    and gone, and the holds (beside the raw diff, which is then the
    review's view)."""
    import os
    files = set()
    for root in (old, new):
        for d, _, fs in os.walk(root):
            for f in fs:
                files.add(os.path.relpath(os.path.join(d, f), root))
    holds = []
    out = []
    for rel in sorted(files):
        a, b = os.path.join(old, rel), os.path.join(new, rel)
        ea, eb = os.path.isfile(a), os.path.isfile(b)
        if ea and eb and open(a, "rb").read() == open(b, "rb").read():
            continue
        ja, xa = load(a) if ea else ({}, None)
        jb, xb = load(b) if eb else ({}, None)
        if xa or xb:
            holds.append(f"{rel} is not JSON ({xa or xb}): the summary cannot read it")
            continue
        fa, fb, kya, kyb, ca, cb = {}, {}, {}, {}, [0, 0], [0, 0]
        flat(ja, "", fa, kya, ca)
        flat(jb, "", fb, kyb, cb)
        if rel in DISPLAY_ONLY:
            display_only(rel, ea, eb, jb, fa, fb, kya, kyb, ca, cb, out, holds)
            continue
        # strings by path, keys included
        sa = {p: v for p, v in fa.items() if isinstance(v, str) and not isinstance(v, Empty)} | kya
        sb = {p: v for p, v in fb.items() if isinstance(v, str) and not isinstance(v, Empty)} | kyb
        na = {p: v for p, v in sa.items() if netish(v)}
        nb = {p: v for p, v in sb.items() if netish(v)}
        state = "new file" if not ea else "removed" if not eb else "changed"
        kind = "domains and holds; the raw diff shows it" if mode == "hosts" else "every changed value"
        out.append(f"## {rel} ({state}; {kind}): keys {ca[0]} -> {cb[0]}, strings {ca[1]} -> {cb[1]}, "
                   f"host strings {len(na)} -> {len(nb)}")
        # the URL checks: every new or changed string that is a URL candidate
        for p in sorted(sb):
            v = sb[p]
            if sa.get(p) == v:
                continue
            _, why = url_check(v, rel, p)
            if why:
                holds.append(f"{rel}: {ascii(p)}: {why}")
            elif not candidate(v) and "@" in v and not re.search(r"\s", v):
                after = v.rsplit("@", 1)[1]
                if HOSTNAME.fullmatch(after.split(":")[0]) or re.fullmatch(r"[0-9.]+(:[0-9]*)?", after):
                    holds.append(f"{rel}: {ascii(p)}: a host with userinfo ({ascii(v)}): "
                                 "used as a netloc, the host is what follows the @")
        if mode == "full":
            gone = 0
            for p in sorted(set(fa) | set(fb)):
                if p in fa and p in fb:
                    if not same(fa[p], fb[p]):
                        out.append(f"~ {ann(p)} = {shown(fa[p], rel)} -> {shown(fb[p], rel)}")
                elif p in fb:
                    out.append(f"+ {ann(p)} = {shown(fb[p], rel)}")
                else:
                    gone += 1
            if gone:
                out.append(f"- {gone} values removed (counted only)")
        ha = {registrable(h) for v in na.values() for h in hosts_in(v, rel)}
        hb = {registrable(h) for v in nb.values() for h in hosts_in(v, rel)}
        if hb - ha:
            out.append("  new registrable domains: " + " ".join(ann(h) for h in sorted(hb - ha)))
        if ha - hb:
            out.append("  gone registrable domains: " + " ".join(ann(h) for h in sorted(ha - hb)))
        old_hosts = {h for v in na.values() for h in hosts_in(v, rel)}
        for h in sorted({h for v in nb.values() for h in hosts_in(v, rel)} - old_hosts):
            if host_letters_mixed(h):
                holds.append(f"{rel}: the host {ascii(h)} mixes scripts (a lookalike domain)")
    for line in out:
        print(line)
    for h in holds:
        print(f"HOLD the searx/data summary: {h}")


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 2 and a[0] == "esc" and a[1] in ("code", "data"):
        esc(a[1])
    elif len(a) == 3 and a[0] == "scan" and a[1] in ("code", "data"):
        scan(a[1], a[2])
    elif len(a) == 2 and a[0] == "mask":
        mask(a[1])
    elif len(a) in (3, 4) and a[0] == "summary" and (a[3:] or ["full"])[0] in ("full", "hosts"):
        summary(a[1], a[2], (a[3:] or ["full"])[0])
    else:
        sys.exit("usage: searxng-text esc code|data | scan code|data FILE | mask COUNT | summary OLD NEW [full|hosts]")
