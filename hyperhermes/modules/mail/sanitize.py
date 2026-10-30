"""What an agent may see of a mail: pure functions, no I/O.

Everything here treats the message as hostile. The rendering follows what a
human would see in a mail client, never more: hidden HTML is dropped, not
shown, and the text/plain alternative of an HTML body is ignored, because a
sender can put text there that no human reader ever sees.
"""

from __future__ import annotations

import base64
import email
import email.policy
import email.utils
import html.parser
import ipaddress
import re
import unicodedata
import urllib.parse

import css_inline

# Characters that render as nothing but still reach a model: zero-width
# joiners and spaces, bidi overrides, soft hyphen, variation selectors and the
# Unicode tag block ("ASCII smuggling").
_INVISIBLE = re.compile(
    "[\u00ad\u034f\u061c\u115f\u1160\u17b4\u17b5\u180b-\u180f\u200b-\u200f"
    "\u202a-\u202e\u2060-\u206f\u3164\ufe00-\ufe0f\ufeff\uffa0"
    "\U0001d173-\U0001d17a\U000e0000-\U000e0fff]"
)
_SPACES = re.compile(r"[ \t\u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]+")

MAX_TEXT = 60_000


def clean_text(s: str, *, newlines: bool = True, limit: int = MAX_TEXT) -> str:
    """NFC, no invisible or control characters, collapsed whitespace."""
    s = unicodedata.normalize("NFC", s)
    s = _INVISIBLE.sub("", s)
    s = s.replace("\r\n", "\n").replace("\r", "\n")
    out = []
    for ch in s:
        if ch == "\n":
            out.append("\n" if newlines else " ")
        elif ch == "\t":
            out.append(" ")
        elif unicodedata.category(ch) in ("Cc", "Cf", "Co", "Cs", "Cn", "Zl", "Zp"):
            continue
        else:
            out.append(ch)
    s = _SPACES.sub(" ", "".join(out))
    s = "\n".join(line.strip() for line in s.split("\n"))
    s = re.sub(r"\n{3,}", "\n\n", s).strip()
    if len(s) > limit:
        s = s[:limit] + "\n[... truncated by mailgate]"
    return s


def clean_line(s: str, limit: int = 200) -> str:
    return clean_text(s or "", newlines=False, limit=limit)


# ---------------------------------------------------------------- HTML

_DROP = {
    "head", "title", "script", "style", "template", "noscript", "svg", "math",
    "iframe", "object", "embed", "canvas", "select", "option", "textarea",
    "video", "audio", "map", "frameset", "frame", "button", "datalist", "dialog",
}
_VOID = {
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
    "param", "source", "track", "wbr", "image",
}
_BLOCK = {
    "p", "div", "tr", "li", "h1", "h2", "h3", "h4", "h5", "h6", "table", "ul",
    "ol", "blockquote", "pre", "section", "article", "header", "footer", "dt",
    "dd", "dl", "center", "address", "figure", "figcaption", "form", "main",
    "nav", "aside", "tbody", "thead", "tfoot", "caption", "fieldset", "details",
    "summary",
}
_NAMED_COLORS = {
    "white": (255, 255, 255), "black": (0, 0, 0), "red": (255, 0, 0),
    "green": (0, 128, 0), "blue": (0, 0, 255), "gray": (128, 128, 128),
    "grey": (128, 128, 128), "silver": (192, 192, 192), "whitesmoke": (245, 245, 245),
    "snow": (255, 250, 250), "ivory": (255, 255, 240), "ghostwhite": (248, 248, 255),
    "floralwhite": (255, 250, 240), "mintcream": (245, 255, 250),
    "azure": (240, 255, 255), "aliceblue": (240, 248, 255), "seashell": (255, 245, 238),
    "linen": (250, 240, 230), "honeydew": (240, 255, 240), "lavenderblush": (255, 240, 245),
    "oldlace": (253, 245, 230), "beige": (245, 245, 220), "lightyellow": (255, 255, 224),
    "lightgray": (211, 211, 211), "lightgrey": (211, 211, 211),
    "gainsboro": (220, 220, 220), "yellow": (255, 255, 0), "navy": (0, 0, 128),
}


def _color(value: str | None):
    """(r, g, b) or None when unknown; "transparent" is 'T'."""
    if not value:
        return None
    v = value.strip().lower().replace("!important", "").strip()
    if v in ("transparent",):
        return "T"
    if v in _NAMED_COLORS:
        return _NAMED_COLORS[v]
    m = re.fullmatch(r"#([0-9a-f]{3,8})", v)
    if m:
        h = m.group(1)
        if len(h) in (3, 4):
            if len(h) == 4 and h[3] == "0":
                return "T"
            return tuple(int(c * 2, 16) for c in h[:3])
        if len(h) in (6, 8):
            if len(h) == 8 and int(h[6:8], 16) < 26:
                return "T"
            return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))
        return None
    m = re.fullmatch(r"rgba?\(([^)]*)\)", v)
    if m:
        parts = [p for p in re.split(r"[\s,/]+", m.group(1)) if p]
        try:
            rgb = tuple(
                round(float(p[:-1]) * 2.55) if p.endswith("%") else round(float(p))
                for p in parts[:3]
            )
            if len(parts) >= 4:
                a = parts[3]
                alpha = float(a[:-1]) / 100 if a.endswith("%") else float(a)
                if alpha < 0.1:
                    return "T"
            return rgb if len(rgb) == 3 else None
        except ValueError:
            return None
    m = re.fullmatch(r"hsla?\(([^)]*)\)", v)
    if m:
        parts = [p for p in re.split(r"[\s,/]+", m.group(1)) if p]
        if len(parts) >= 4:
            a = parts[3]
            try:
                alpha = float(a[:-1]) / 100 if a.endswith("%") else float(a)
                if alpha < 0.1:
                    return "T"
            except ValueError:
                pass
        if len(parts) >= 3 and parts[2].endswith("%"):
            try:
                light = float(parts[2][:-1]) / 100
                g = round(light * 255)
                return (g, g, g)
            except ValueError:
                return None
    return None


def _luminance(rgb) -> float:
    r, g, b = (c / 255 for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


# Escapes in CSS identifiers and values (`d\isplay`, `\64 isplay`): a browser
# reads them as the plain character, so matching happens after decoding.
_CSS_ESCAPE = re.compile(r"\\(?:([0-9a-fA-F]{1,6})[ \t\r\n\f]?|(.))", re.S)


def _css_unescape(s: str) -> str:
    def one(m):
        if m.group(1):
            cp = int(m.group(1), 16)
            return chr(cp) if 0 < cp <= 0x10FFFF and not 0xD800 <= cp <= 0xDFFF else "\ufffd"
        return m.group(2)

    return _CSS_ESCAPE.sub(one, s) if "\\" in s else s


def _strip_css_comments(css: str) -> str:
    """Comments out, in one pass. An unterminated comment runs to the end, as
    in a browser. Removing a comment joins its neighbours (`dis/**/play`),
    which can only make more declarations match, never fewer."""
    if "/*" not in css:
        return css
    out, i = [], 0
    while True:
        j = css.find("/*", i)
        if j < 0:
            out.append(css[i:])
            break
        out.append(css[i:j])
        k = css.find("*/", j + 2)
        if k < 0:
            break
        i = k + 2
    return "".join(out)


def _style(value: str | None) -> dict[str, str]:
    """Declarations as the cascade resolves them inside one block: the last
    one wins, except that an `!important` one beats every plain one."""
    decls: dict[str, str] = {}
    important: set[str] = set()
    for decl in _css_unescape(_strip_css_comments(value or "")).split(";"):
        if ":" in decl:
            k, v = decl.split(":", 1)
            k, v = k.strip().lower(), v.strip().lower()
            v, n = _IMPORTANT.subn("", v)
            if n:
                important.add(k)
            elif k in important:
                continue
            decls[k] = v.strip()
    return decls


_IMPORTANT = re.compile(r"!\s*important\s*$")
_LENGTH = re.compile(r"([+-]?[0-9]{0,32}\.?[0-9]{1,32})\s*([a-z%]{0,8})")
# Values a renderer cannot judge without evaluating them: exponents
# (1e-9px; not the "1e1" inside a #1e1e1e colour), maths and variables.
# Where a size, offset, opacity or colour takes one, the element counts as
# hidden. Possessive quantifiers keep a long digit run linear.
_COMPUTED = re.compile(
    r"(?<![#\w.])(?:[0-9]++(?:\.[0-9]*+)?|\.[0-9]++)e[+-]?[0-9]|\b(?:calc|clamp|min|max|var|env|attr)\s*\("
)


def _length(v: str):
    """(number, unit) of a CSS length, or None."""
    m = _LENGTH.match(v or "")
    if not m:
        return None
    return float(m.group(1)), m.group(2)


def _tiny(ln) -> bool:
    """A box edge a reader cannot see text through (sr-only uses 1px)."""
    return bool(ln) and (ln[0] <= 0 or (ln[1] in ("px", "pt", "") and ln[0] < 4))


def _font_size(font: str) -> str:
    """The size of a `font` shorthand ([style variant weight] size[/line-height]
    family): the word before a '/', else the first length with a unit or a
    bare 0. Weights (700) and families are not sizes."""
    words = font.replace("/", " / ").split()
    if "/" in words:
        i = words.index("/")
        return words[i - 1] if i else ""
    for w in words:
        ln = _length(w)
        if ln and _LENGTH.fullmatch(w) and (ln[1] or ln[0] == 0):
            return w
    return ""


_SIZE_PROPS = (
    "opacity", "font", "font-size", "height", "max-height", "width", "max-width", "line-height",
    "text-indent", "left", "top", "margin-left", "margin-top", "right", "color",
)


def _hides_structurally(style: dict[str, str]) -> bool:
    """display:none, visibility:hidden and Outlook's mso-hide: what hides an
    element in every client, whatever its size or colours."""
    return (
        style.get("display") == "none"
        or style.get("visibility") in ("hidden", "collapse")
        or style.get("mso-hide") == "all"
    )


def _hides(style: dict[str, str]) -> bool:
    """True when these declarations make an element invisible to a reader."""
    if not style:
        return False
    if _hides_structurally(style):
        return True
    if any(_COMPUTED.search(style.get(p, "")) for p in _SIZE_PROPS):
        return True
    op = _length(style.get("opacity", ""))
    if op and (op[0] < 0.1 if op[1] != "%" else op[0] < 10):
        return True
    for size in (style.get("font-size", ""), _font_size(style.get("font", ""))):
        fs = _length(size)
        if fs:
            n, unit = fs
            if n <= 0 or (unit in ("px", "pt", "") and n < 5) or (
                unit in ("em", "rem") and n < 0.35
            ) or (unit == "%" and n < 35):
                return True
    for prop in ("height", "max-height", "width", "max-width", "line-height"):
        ln = _length(style.get(prop, ""))
        if ln and ln[0] <= 0 and not (prop == "line-height" and "overflow" not in style):
            return True
    if style.get("overflow", "").split()[:1] in (["hidden"], ["clip"]) and any(
        _tiny(_length(style.get(p, ""))) for p in ("height", "max-height", "width", "max-width")
    ):
        return True
    for prop in ("text-indent", "left", "top", "margin-left", "margin-top", "right"):
        ln = _length(style.get(prop, ""))
        if ln and ln[0] <= -500:
            return True
    # Clipping and transforms have too many ways to shrink a box to nothing
    # (inset(51%), scale(0.01), matrix(...)); mail almost never needs them.
    if style.get("clip", "auto") not in ("", "auto") or style.get("clip-path", "none") not in ("", "none"):
        return True
    if style.get("transform", "none") not in ("", "none"):
        return True
    if _color(style.get("color")) == "T":
        return True
    return False


# ---------------------------------------------------------------- stylesheets
#
# <style> rules are resolved the way a desktop webmail client in light mode
# shows the mail: css-inline matches every selector (descendants,
# attributes, specificity, !important) and writes the outcome into style
# attributes, which the renderer reads like any inline style. :hover and
# the like never match a document at rest, so they change nothing here.

# Caps that keep rendering linear in practice: more CSS than this hides
# the whole body; more HTML than this is not rendered at all. css-inline
# recurses once per nesting level (about 7000 levels overflow an 8 MiB
# stack and kill the process), so deeper markup keeps only its inline
# styles.
MAX_CSS = 65_536
MAX_HTML = 2_000_000
MAX_DEPTH = 1_000

# The reading pane a media query is evaluated against: a condition holds
# when it holds for every pane width from 800 to 1024 px (min-width up to
# 800px, max-width from 1024px), on a screen, in light mode, in landscape,
# at one device pixel per CSS pixel. Print, dark mode, mobile max-width
# breakpoints and features not known here do not apply.
_PANE = (800, 1024)
_MEDIA_FEATURE = re.compile(r"\(\s*([-a-z]+)\s*(?::\s*([^)]*?)\s*)?\)")
_MEDIA_TYPES = {"all", "screen", "print", "speech", "tv", "projection", "handheld", "aural", "braille", "embossed", "tty"}
_PX = {"px": 1, "": 1, "em": 16, "rem": 16, "pt": 4 / 3}


def _px(value: str):
    m = _LENGTH.fullmatch(value)
    if not m or m.group(2) not in _PX or (not m.group(2) and float(m.group(1)) != 0):
        return None
    return float(m.group(1)) * _PX[m.group(2)]


def _media_feature(name: str, value: str | None) -> bool | None:
    """Whether `(name: value)` holds for the pane; None when unknown."""
    name = re.sub(r"^-(?:webkit|moz|o)-", "", name)
    if name in ("min-width", "max-width", "min-device-width", "max-device-width"):
        px = _px(value or "")
        if px is None:
            return None
        return px <= _PANE[0] if name.startswith("min") else px >= _PANE[1]
    if name in ("min-device-pixel-ratio", "max-device-pixel-ratio"):
        try:
            ratio = float(value or "")
        except ValueError:
            return None
        return ratio <= 1 if name.startswith("min") else ratio >= 1
    if name == "prefers-color-scheme":
        return value in (None, "light")
    if name == "orientation":
        return value == "landscape"
    return None


def _media_query(query: str) -> bool:
    ok = True
    for m in _MEDIA_FEATURE.finditer(query):
        got = _media_feature(m.group(1), m.group(2))
        if got is None:
            return False
        ok = ok and got
    words = _MEDIA_FEATURE.sub(" ", query).split()
    negated = words[:1] == ["not"]
    rest = [w for w in words if w not in ("only", "not", "and")]
    if len(rest) > 1 or (rest and rest[0] not in _MEDIA_TYPES):
        return False
    if rest and rest[0] not in ("all", "screen"):
        ok = False
    return ok != negated


def _media_applies(queries: str) -> bool:
    """Whether an @media query list (lowercase, after "@media") applies."""
    return any(_media_query(q.strip()) for q in queries.split(","))


def _desktop_css(css: str) -> str:
    """The rules of a stylesheet that apply in the pane, without at-rules:
    the rules of an @media that applies and of every @supports move to the
    top level; other at-rules and nested blocks are dropped. One pass."""
    css = _strip_css_comments(css)
    out: list[str] = []
    stack: list[str] = []  # "rule" or "group" per open block
    skip = 0  # depth inside a dropped block
    seg = 0
    for m in re.finditer(r"[{};]", css):
        i, ch = m.start(), m.group()
        if skip:
            skip += 1 if ch == "{" else -1 if ch == "}" else 0
        elif ch == ";":
            # Declarations of a rule stay; an at-statement (@import) or junk
            # between rules goes.
            if stack and stack[-1] == "rule":
                out.append(css[seg : i + 1])
        elif ch == "{":
            prelude = css[seg:i].strip()
            at = re.match(r"@([-a-z]+)(.*)", _css_unescape(prelude).lower(), re.S) if prelude.startswith("@") else None
            if stack and stack[-1] == "rule":
                skip = 1
            elif at is None and not prelude.startswith("@"):
                out.append(prelude + "{")
                stack.append("rule")
            elif at and (at.group(1) == "supports" or (at.group(1) == "media" and _media_applies(at.group(2)))):
                stack.append("group")
            else:
                skip = 1
        elif stack and stack.pop() == "rule":
            out.append(css[seg:i] + "}")
        seg = i + 1
    if stack and stack[-1] == "rule":
        out.append(css[seg:] + "}")
    return "".join(out)


class _TooDeep(Exception):
    pass


class _Depth(html.parser.HTMLParser):
    """Raises _TooDeep once elements nest more than MAX_DEPTH deep."""

    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.stack: list[str] = []
        self.open: dict[str, int] = {}

    def handle_starttag(self, tag, attrs):
        if tag in _VOID:
            return
        self.stack.append(tag)
        self.open[tag] = self.open.get(tag, 0) + 1
        if len(self.stack) > MAX_DEPTH:
            raise _TooDeep

    def handle_startendtag(self, tag, attrs):
        pass

    def handle_endtag(self, tag):
        if not self.open.get(tag):
            return
        while self.stack:
            t = self.stack.pop()
            self.open[t] -= 1
            if t == tag:
                break


def _inline_stylesheet(markup: str, css: str) -> str | None:
    """`markup` with `css` resolved into style attributes and without its
    <style> and <link> elements, or None when css-inline cannot do that:
    it failed, or the markup nests too deep for it. Nothing is fetched."""
    depth = _Depth()
    try:
        depth.feed(markup)
        depth.close()
    except _TooDeep:
        return None
    except Exception:  # noqa: BLE001 - css-inline parses it its own way
        pass
    try:
        return css_inline.CSSInliner(
            inline_style_tags=False,
            keep_style_tags=False,
            keep_link_tags=False,
            keep_at_rules=False,
            load_remote_stylesheets=False,
            extra_css=css,
        ).inline(markup)
    except Exception:  # noqa: BLE001 - InlineError, pathological CSS or markup
        return None


class _Renderer(html.parser.HTMLParser):
    """Visible text of markup whose stylesheet is already inline. `lenient`
    hides only structurally (display, visibility, the hidden attribute,
    closed <details>, tags that never render), without the size and contrast
    rules; `hide_all` hides every element."""

    def __init__(self, *, lenient: bool = False, hide_all: bool = False):
        super().__init__(convert_charrefs=True)
        self.lenient = lenient
        self.hide_all = hide_all
        # (tag, hidden, color, background, closed <details>)
        self.stack: list[tuple[str, bool, object, object, bool]] = []
        # How often each tag is open, so an end tag never scans the stack.
        self.open: dict[str, int] = {}
        self.out: list[str] = []
        self.size = 0
        self.hrefs: list[str] = []
        self.anchor: list[tuple[str | None, int, int]] = []
        self.hidden_elements = 0
        self.images = 0

    def _emit(self, s: str) -> None:
        self.out.append(s)
        self.size += len(s)

    def _top(self):
        if self.stack:
            return self.stack[-1]
        return ("", False, (0, 0, 0), (255, 255, 255), False)

    def handle_starttag(self, tag, attrs_list):
        tag = tag.lower()
        # A browser keeps the first of duplicate attributes; so does this.
        attrs: dict[str, str] = {}
        for k, v in attrs_list:
            attrs.setdefault(k.lower(), v or "")
        _, parent_hidden, parent_color, parent_bg, in_closed_details = self._top()
        if tag == "img" or tag == "image" or tag == "picture":
            self.images += 1
            return
        if tag in ("br",):
            if not parent_hidden:
                self._emit("\n")
            return
        if tag == "hr":
            if not parent_hidden:
                self._emit("\n----\n")
            return
        if tag in _VOID:
            return
        style = _style(attrs.get("style"))
        color = _color(style.get("color") or attrs.get("color") or (attrs.get("text") if tag == "body" else None))
        if color is None:
            color = parent_color
        bg = _color(
            style.get("background-color")
            or (style.get("background", "").split() or [None])[0]
            or attrs.get("bgcolor")
        )
        if bg in (None, "T"):
            bg = parent_bg
        hidden = parent_hidden
        if not hidden:
            hidden = (
                self.hide_all
                or tag in _DROP
                or "hidden" in attrs
                # A closed <details> shows its <summary> only.
                or (in_closed_details and tag != "summary")
                or (
                    _hides_structurally(style)
                    if self.lenient
                    else attrs.get("aria-hidden", "").lower() == "true" or _hides(style)
                )
            )
            if hidden:
                self.hidden_elements += 1
        closed = tag == "details" and "open" not in attrs
        self.stack.append((tag, hidden, color, bg, closed))
        self.open[tag] = self.open.get(tag, 0) + 1
        if not hidden:
            if tag in _BLOCK:
                self._emit("\n")
            if tag == "li":
                self._emit("- ")
            if tag in ("td", "th"):
                self._emit(" ")
            if tag == "a":
                self.anchor.append((attrs.get("href"), len(self.out), self.size))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag.lower() not in _VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        tag = tag.lower()
        if not self.open.get(tag):
            return
        while self.stack:
            t, hidden, *_ = self.stack.pop()
            self.open[t] -= 1
            if not hidden:
                if t == "a" and self.anchor:
                    href, start, start_size = self.anchor.pop()
                    if href and re.match(r"(?i)https?://", href.strip()):
                        href = href.strip()
                        if len(self.hrefs) < 1000:
                            self.hrefs.append(href)
                        # Join the link text only when it can be the bare
                        # URL; nested anchors would make this quadratic.
                        same = self.size - start_size <= 2 * len(href) + 64 and (
                            "".join(self.out[start:]).strip() == href
                        )
                        if not same:
                            self._emit(f" <{href}>")
                if t in _BLOCK:
                    self._emit("\n")
            if t == tag:
                break

    def handle_data(self, data):
        _, hidden, color, bg, in_closed_details = self._top()
        if hidden:
            return
        if in_closed_details:
            self.hidden_elements += 1
            return
        # Colours decide per run of text, not per element: a dark box can
        # hold a light paragraph.
        if (
            not self.lenient
            and data.strip()
            and isinstance(color, tuple)
            and isinstance(bg, tuple)
            and abs(_luminance(color) - _luminance(bg)) < 0.12
        ):
            self.hidden_elements += 1
            return
        self._emit(data)


def _style_blocks(markup: str) -> str | None:
    """The text of every <style> element, found with plain searches; None
    when there is more than MAX_CSS of it. An unclosed <style> runs to the
    end, as HTMLParser reads it."""
    low = markup.lower()
    out, size, i = [], 0, 0
    while True:
        j = low.find("<style", i)
        if j < 0:
            break
        k = low.find(">", j)
        if k < 0:
            break
        end = low.find("</style", k)
        if end < 0:
            end = len(low)
        size += end - k - 1
        if size > MAX_CSS:
            return None
        out.append(markup[k + 1 : end])
        i = end + 1
    return "\n".join(out)


def _render_html(markup: str, **kw) -> _Renderer:
    r = _Renderer(**kw)
    try:
        r.feed(markup)
        r.close()
    except Exception:  # noqa: BLE001 - malformed markup degrades, never crashes
        pass
    return r


# A strict rendering with fewer visible characters than this, of a mail
# whose structural rendering has at least this many more, is replaced by
# the structural one (`lenient`): an allowlisted sender's template that the
# size and contrast rules empty is more likely a misjudged layout than a
# hidden message.
LENIENT_BELOW = 40


def _visible(text: str) -> int:
    return len("".join(text.split()))


def html_to_text(markup: str) -> tuple[str, list[str], int, int, bool]:
    """(visible text, hrefs of visible links, hidden elements, images,
    lenient). Callers keep `markup` under MAX_HTML (render() does)."""
    styles = _style_blocks(markup)
    if styles is None:
        # Too much CSS to judge: nothing shows, not even leniently.
        r = _render_html(markup, hide_all=True)
        return clean_text("".join(r.out)), r.hrefs, r.hidden_elements, r.images, False
    css = _desktop_css(styles)
    if "{" in css:
        # When css-inline fails, the <style> elements count for nothing:
        # the renderer drops them and judges the inline styles alone.
        markup = _inline_stylesheet(markup, css) or markup
    r = _render_html(markup)
    text = clean_text("".join(r.out))
    lenient = False
    if r.hidden_elements and _visible(text) < LENIENT_BELOW:
        loose = _render_html(markup, lenient=True)
        loose_text = clean_text("".join(loose.out))
        if _visible(loose_text) >= _visible(text) + LENIENT_BELOW:
            r, text, lenient = loose, loose_text, True
    return text, r.hrefs, r.hidden_elements, r.images, lenient


# ---------------------------------------------------------------- MIME


def parse(raw: bytes) -> email.message.EmailMessage:
    return email.message_from_bytes(raw, policy=email.policy.default)


def _part_text(part) -> str:
    try:
        return part.get_content()
    except Exception:  # noqa: BLE001 - unknown charset, broken encoding
        payload = part.get_payload(decode=True) or b""
        return payload.decode("utf-8", "replace")


def _decoded_size(part) -> int:
    try:
        return len(part.get_payload(decode=True) or b"")
    except Exception:  # noqa: BLE001
        return 0


def _leaves(part):
    """Leaf parts in order. An attached message (message/rfc822) is one leaf:
    nothing inside it is rendered or listed separately."""
    if part.get_content_type() == "message/rfc822" or not part.is_multipart():
        yield part
        return
    for kid in part.get_payload():
        yield from _leaves(kid)


def body_and_attachments(msg):
    """Pick the body a mail client would show (HTML over plain) and list every
    other leaf part as an attachment, numbered from 1. Alternatives of the
    chosen body are neither shown nor listed."""
    body = msg.get_body(preferencelist=("html", "plain"))
    skip = set()
    if body is not None:
        skip.add(id(body))
        for part in msg.walk():
            if part.get_content_type() == "multipart/alternative" and any(
                k is body for k in _leaves(part)
            ):
                skip.update(id(k) for k in _leaves(part))
    attachments = []
    for part in _leaves(msg):
        if id(part) in skip:
            continue
        attachments.append(
            {
                "index": len(attachments) + 1,
                "name": clean_line(part.get_filename() or "", 120) or "(unnamed)",
                "type": clean_line(part.get_content_type(), 80),
                "size": _decoded_size(part),
                "_part": part,
            }
        )
    return body, attachments


def render(msg) -> dict:
    """The visible text of a message plus what was dropped. HTML above
    MAX_HTML is not rendered at all (`too_large`); `lenient` says the text
    is html_to_text's structural fallback."""
    body, attachments = body_and_attachments(msg)
    text, hrefs, hidden, images, lenient, too_large = "", [], 0, 0, False, False
    if body is not None:
        content = _part_text(body)
        if body.get_content_type() == "text/html":
            if len(content) > MAX_HTML:
                too_large = True
            else:
                text, hrefs, hidden, images, lenient = html_to_text(content)
        else:
            # clean_text keeps MAX_TEXT anyway; do not walk megabytes for it.
            text = clean_text(content[: 4 * MAX_TEXT])
    return {
        "text": text,
        "hrefs": hrefs,
        "hidden": hidden,
        "images": images,
        "html": body is not None and body.get_content_type() == "text/html",
        "too_large": too_large,
        "lenient": lenient,
        "attachments": attachments,
    }


def attachment_bytes(msg, index: int):
    """(name, type, bytes) of attachment `index` as render() numbers them."""
    _, attachments = body_and_attachments(msg)
    for a in attachments:
        if a["index"] == index:
            part = a["_part"]
            if part.get_content_type() == "message/rfc822":
                data = part.as_bytes()
            else:
                data = part.get_payload(decode=True) or b""
            return a["name"], a["type"], data
    return None


def public_attachments(attachments) -> list[dict]:
    return [{k: v for k, v in a.items() if not k.startswith("_")} for a in attachments]


# ---------------------------------------------------------------- authentication


class _Odd(Exception):
    """An Authentication-Results header Stalwart would not have written."""


def _ar_words(value: str) -> list[list[str]]:
    """RFC 8601 resinfo segments of one unfolded header value, as lists of
    words, comments dropped. Raises _Odd on anything Stalwart never writes:
    quoted strings or quoted pairs (mailgate's hook keeps quotes out of MAIL
    FROM and EHLO; DKIM tags, the other free text Stalwart copies in, are
    checked by dkim_signatures), unbalanced comments, control or non-ASCII
    characters."""
    segments: list[list[str]] = [[]]
    word: list[str] = []
    depth = 0

    def end_word():
        if word:
            segments[-1].append("".join(word))
            word.clear()

    for ch in value:
        if ch in "\r\n\t":
            ch = " "
        if not (" " <= ch <= "~"):
            raise _Odd("control or non-ASCII character")
        if ch in '"\\':
            raise _Odd("quoted string or quoted pair")
        if depth:
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            continue
        if ch == "(":
            end_word()
            depth = 1
        elif ch == ")":
            raise _Odd("unbalanced comment")
        elif ch == " ":
            end_word()
        elif ch == ";":
            end_word()
            segments.append([])
        else:
            word.append(ch)
    if depth:
        raise _Odd("unterminated comment")
    end_word()
    return segments


def _ar_authserv(value: str) -> str:
    """The authserv-id of a raw header value, best effort (no validation)."""
    head = value.split(";", 1)[0].split()
    return head[0].lower() if head else ""


# What Stalwart copies from a DKIM-Signature into its Authentication-Results
# (mail-auth 0.7.5, common/auth_results.rs): header.d=<d> or, when i= is
# set, header.i=<i> instead; then header.s=<s> and header.b=<first 6 bytes
# of b=, base64>. d= and s= lose their whitespace and are lowercased; i= is
# dkim-quoted-printable decoded (=3B is ';', =20 a space) and copied
# verbatim. So these three must be plain names before any result counts.
_LABEL = r"[a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?"
_DKIM_NAME = re.compile(rf"{_LABEL}(?:\.{_LABEL})*")
_DKIM_AUID = re.compile(rf"[a-z0-9!#$%&'*+/?^_`{{|}}~.-]{{0,64}}@{_LABEL}(?:\.{_LABEL})*")
_ASCII_SPACE = b" \t\n\r\x0c"
_SPACE_RUN = re.compile(rb"[ \t\r\x0c]*")
_NAME_LEAD = re.compile(rb"[ \t\r\x0c:]*")


def _stalwart_headers(raw: bytes) -> list[tuple[bytes, bytes]]:
    """(name, value) of the top-level headers, split the way Stalwart's
    parser (mail-parser 0.11, parsers/header.rs and fields/raw.rs) splits
    them before mail-auth sees them, which is not Python's way: leading
    whitespace before a header is skipped, a line without ':' is dropped,
    and the name is every non-space byte before the ':' ("DKIM - Signature :"
    is a DKIM-Signature), lowercased and cut at 30 bytes. A value runs to a
    line feed not followed by a space or tab; the headers end at a line
    holding nothing but whitespace.

    Run on what mailgate receives, Stalwart's own headers come first. If the
    sender's first header line starts with whitespace, it continues
    Stalwart's last header here, while Stalwart saw a header of its own:
    this view then holds fewer DKIM-Signatures than Stalwart verified,
    never more, and auth_results refuses the count mismatch.
    """
    out = []
    pos, n = 0, len(raw)
    while True:
        pos = _SPACE_RUN.match(raw, pos).end()
        if pos >= n or raw[pos] == 0x0A:
            return out
        nl = raw.find(b"\n", pos)
        line = raw[pos:] if nl < 0 else raw[pos:nl]
        # The name starts at the first byte that is neither space nor ':'
        # (colons before it are skipped) and ends at the next ':'.
        token = _NAME_LEAD.match(line).end()
        colon = line.find(b":", token) if token < len(line) else -1
        if colon < 0:
            if nl < 0:
                # A name cut off by the end of the message: an empty header.
                if token < len(line):
                    out.append((line[token:].translate(None, _ASCII_SPACE)[:30].lower(), b""))
                return out
            pos = nl + 1
            continue
        name = line[:colon].translate(None, _ASCII_SPACE + b":")[:30].lower()
        start = end = pos + colon + 1
        while True:
            nl = raw.find(b"\n", end)
            if nl < 0:
                end = n
                break
            end = nl + 1
            if end < n and raw[end] in (0x20, 0x09):
                end += 1
                continue
            break
        out.append((name, raw[start:end]))
        pos = end


def _dkim_tags(value: bytes) -> dict:
    """d, s, i and b of one DKIM-Signature as mail-auth reads them (b as
    bytes, None when it is not base64). Raises _Odd on anything a plain
    signature never holds and mail-auth might read differently: a tag
    without '=', d/s/i/b twice, a d/s/i outside the name grammar."""
    try:
        text = value.decode("ascii")
    except UnicodeDecodeError:
        raise _Odd("non-ASCII DKIM-Signature") from None
    tags: dict = {}
    for piece in text.split(";"):
        # mail-auth drops exactly these (is_ascii_whitespace), nothing else.
        piece = re.sub(r"[ \t\n\r\x0c]+", "", piece)
        if not piece:
            continue
        name, eq, val = piece.partition("=")
        if not eq:
            raise _Odd("DKIM tag without '='")
        name = name.lower()
        if name not in ("d", "s", "i", "b"):
            continue
        if name in tags:
            raise _Odd(f"DKIM tag {name}= twice")
        if name == "b":
            try:
                tags["b"] = base64.b64decode(val + "=" * (-len(val) % 4), validate=True)
            except ValueError:
                tags["b"] = None
            continue
        if len(val) > 760:
            raise _Odd(f"DKIM {name}= too long")
        if name == "i":
            if not re.fullmatch(r"(?:[^=]|=[0-9a-fA-F]{2})*", val):
                raise _Odd("DKIM i= with a stray '='")
            val = re.sub(r"=([0-9a-fA-F]{2})", lambda m: chr(int(m.group(1), 16)), val).lower()
            if len(val) > 254 or not _DKIM_AUID.fullmatch(val):
                raise _Odd("DKIM i= outside dot-atom@hostname")
        else:
            val = val.lower()
            if len(val) > 253 or not _DKIM_NAME.fullmatch(val):
                raise _Odd(f"DKIM {name}= outside the hostname grammar")
        tags[name] = val
    return tags


def dkim_signatures(raw: bytes) -> list[dict]:
    """The tags of every DKIM-Signature Stalwart verified, in order."""
    return [_dkim_tags(v) for k, v in _stalwart_headers(raw) if k == b"dkim-signature"]



_RESULT = re.compile(r"[a-z][a-z0-9-]*")
# The properties Stalwart (mail-auth 0.7) writes per method; anything else
# came from somewhere it copied in. A dkim result carries header.d or
# header.i, never both, and header.s and header.b only with one of them.
_PROPS = {
    "dkim": {"header.d", "header.i", "header.s", "header.b"},
    "spf": {"smtp.mailfrom", "smtp.helo"},
    "iprev": {"policy.iprev"},
    "arc": {"smtp.remote-ip"},
    "dmarc": {"header.from", "policy.dmarc"},
}


def _ar_entry(method: str, entry: dict, sigs: list[dict]) -> None:
    """Raise _Odd unless `entry` fits its method's properties; a dkim entry
    must also be exactly what mail-auth writes for the signature it pairs
    with, and gets that signature's d= as "d"."""
    props = set(entry) - {"result"}
    if method not in _PROPS or not props <= _PROPS[method]:
        raise _Odd(f"{method} properties")
    if method == "spf" and len(props) != 1:
        raise _Odd("spf properties")
    if method != "dkim":
        return
    sig = sigs.pop(0) if sigs else None
    if sig is None:
        raise _Odd("more dkim results than DKIM-Signature headers")
    if not props:
        # A signature mail-auth could not parse: no tags, never a pass.
        if entry["result"] == "pass":
            raise _Odd("dkim pass without a signature")
        return
    if not sig.get("d") or not sig.get("s"):
        raise _Odd("dkim result for an incomplete signature")
    want = {"header.s": sig["s"]}
    if sig.get("i"):
        want["header.i"] = sig["i"]
    else:
        want["header.d"] = sig["d"]
    if sig.get("b") is not None and len(sig["b"]) >= 6:
        want["header.b"] = base64.b64encode(sig["b"][:6]).decode().lower()
    if {k: entry[k] for k in props} != want:
        raise _Odd("dkim result does not match its signature")
    entry["d"] = sig["d"]


def auth_results(msg, raw: bytes, authserv_id: str) -> dict[str, list[dict]]:
    """Stalwart's verdicts: {method: [{"result", property: value}, ...]}.

    Fails closed: {} (read by every caller as "not authenticated") unless
      - the FIRST Authentication-Results header carries our authserv-id
        (Stalwart prepends its own above the original headers),
      - no other header carries it (a sender's forgery, or Stalwart no
        longer adding its own),
      - it lexes cleanly as RFC 8601 (see _ar_words), every result is
        `method=result` with a method and properties Stalwart writes,
      - it holds exactly one dmarc result and that is the last one, which is
        where Stalwart writes it, after everything copied from the session,
      - the message's DKIM-Signature tags that Stalwart copies in (d=, s=,
        i=) are plain names (dkim_signatures), and there is one dkim
        result per DKIM-Signature, in order, each exactly what mail-auth
        writes for that signature. A dkim entry then carries the
        signature's d= as "d", also when Stalwart wrote header.i.
    The raw header value is used: str() would decode RFC 2047 words, which
    can smuggle ';' out of a DKIM tag.
    """
    raws = [v for k, v in msg.raw_items() if k.lower() == "authentication-results"]
    if not raws or _ar_authserv(raws[0]) != authserv_id.lower():
        return {}
    if sum(_ar_authserv(v) == authserv_id.lower() for v in raws) != 1:
        return {}
    try:
        sigs = dkim_signatures(raw)
        segments = _ar_words(raws[0])
        head = segments[0]
        if not head or head[0].lower() != authserv_id.lower() or len(head) > 2:
            raise _Odd("authserv-id")
        res: dict[str, list[dict]] = {}
        methods = []
        for words in segments[1:]:
            if not words or words == ["none"]:
                raise _Odd("empty result")
            method, eq, result = words[0].lower().partition("=")
            method = method.split("/", 1)[0]
            if not eq or not _RESULT.fullmatch(method) or not _RESULT.fullmatch(result):
                raise _Odd("method=result")
            entry = {"result": result}
            for w in words[1:]:
                k, eq, v = w.partition("=")
                k = k.lower()
                if not eq or "." not in k or k in entry:
                    raise _Odd("property")
                entry[k] = v.lower()
            _ar_entry(method, entry, sigs)
            res.setdefault(method, []).append(entry)
            methods.append(method)
        if sigs:
            raise _Odd("fewer dkim results than DKIM-Signature headers")
        if methods.count("dmarc") != 1 or methods[-1] != "dmarc":
            raise _Odd("dmarc must be the single, last result")
    except _Odd:
        return {}
    return res


def sender(msg):
    """The single From address (lowercased) and its display name, or
    (None, "") when From is missing or names more than one mailbox."""
    froms = msg.get_all("From") or []
    if len(froms) != 1:
        return None, ""
    addrs = email.utils.getaddresses([str(froms[0])])
    addrs = [(n, a) for n, a in addrs if a]
    if len(addrs) != 1:
        return None, ""
    name, addr = addrs[0]
    addr = addr.strip().lower()
    if not re.fullmatch(r"[^@\s]+@[a-z0-9.-]+\.[a-z0-9-]+", addr):
        return None, ""
    return addr, clean_line(name, 80)


def _dkim_aligned(entry: dict, domain: str) -> bool:
    """A passing signature by exactly `domain`: its d= (auth_results takes
    it from the signature itself). header.i is no evidence: mail-auth does
    not check that i= lies under d=."""
    return entry.get("result") == "pass" and entry.get("d") == domain


def verdict(msg, raw: bytes, authserv_id: str) -> dict:
    """Who sent this, as far as Stalwart could authenticate it.

    aligned: DMARC passed for the From domain. Domain-level only: SPF alone
    passes it (any tenant of an ESP in the domain's SPF record) and so does
    relaxed alignment (DKIM by any subdomain).
    dkim_aligned: additionally a DKIM signature by exactly the From domain
    passed. This is what the INBOX requires. It still proves nothing about
    the local part: anyone the domain signs for can use any address in it.
    """
    addr, name = sender(msg)
    ar = auth_results(msg, raw, authserv_id)
    dmarc = (ar.get("dmarc") or [{}])[0]
    dkims = ar.get("dkim", [])
    domain = addr.rsplit("@", 1)[1] if addr else None
    aligned = bool(
        addr
        and dmarc.get("result") == "pass"
        and dmarc.get("header.from") == domain
    )
    dkim_aligned = aligned and any(_dkim_aligned(d, domain) for d in dkims)

    def summary(entries):
        results = [e["result"] for e in entries]
        return "pass" if "pass" in results else (results[0] if results else "none")

    return {
        "from": addr,
        "from_name": name,
        "from_domain": domain,
        "dmarc": dmarc.get("result", "none"),
        "spf": summary(ar.get("spf", [])),
        "dkim": summary(dkims),
        "aligned": aligned,
        "dkim_aligned": dkim_aligned,
    }


# ---------------------------------------------------------------- public suffix


class Psl:
    """Organizational domain lookup over a publicsuffix.org list file."""

    def __init__(self, path: str | None):
        self.rules: set[str] = set()
        self.exceptions: set[str] = set()
        self.wild: set[str] = set()
        if not path:
            return
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip().lower()
                if not line or line.startswith("//"):
                    continue
                rule = line.split()[0]
                if rule.startswith("!"):
                    self.exceptions.add(rule[1:])
                elif rule.startswith("*."):
                    self.wild.add(rule[2:])
                else:
                    self.rules.add(rule)

    def org_domain(self, domain: str) -> str:
        labels = domain.lower().strip(".").split(".")
        suffix_len = 1
        for i in range(len(labels)):
            cand = ".".join(labels[i:])
            if cand in self.exceptions:
                suffix_len = len(labels) - i - 1
                break
            if cand in self.rules:
                suffix_len = len(labels) - i
                break
            if i + 1 < len(labels) and ".".join(labels[i + 1 :]) in self.wild:
                suffix_len = len(labels) - i
                break
        return ".".join(labels[-(suffix_len + 1) :]) if len(labels) > suffix_len else domain


# ---------------------------------------------------------------- quarantine view

_URL = re.compile(r"(?i)\bhttps?://[^\s<>\"'()\[\]{}]+")
_CODE = re.compile(r"(?<![\w.-])(\d{3}[- ]\d{3}|\d{4,10})(?![\w-])")

SUBJECT_WORDS = {
    "verify": "verify", "verification": "verify", "verifying": "verify",
    "confirm": "confirm", "confirmation": "confirm",
    "code": "code", "otp": "code", "passcode": "code", "pin": "code",
    "one-time": "one-time", "password": "password", "reset": "reset",
    "login": "login", "log in": "login", "sign in": "login", "sign-in": "login",
    "signin": "login", "sign up": "signup", "sign-up": "signup", "signup": "signup",
    "register": "signup", "registration": "signup", "welcome": "welcome",
    "activate": "activate", "activation": "activate", "invite": "invite",
    "invitation": "invite", "security": "security", "alert": "alert",
    "2fa": "2fa", "two-factor": "2fa", "magic link": "magic-link",
    "invoice": "invoice", "receipt": "receipt", "order": "order",
    "subscription": "subscription", "newsletter": "newsletter",
    "shipping": "shipping", "delivery": "delivery", "account": "account",
}


def subject_keywords(subject: str) -> list[str]:
    """The subject reduced to words of a fixed vocabulary. The sender picks
    the subject, so its text never reaches the agent; only which of these
    known words occur in it, in vocabulary order."""
    low = clean_line(subject or "", 400).lower()
    found = []
    for word, token in SUBJECT_WORDS.items():
        if re.search(r"(?<![\w-])" + re.escape(word) + r"(?![\w-])", low) and token not in found:
            found.append(token)
    return found


def codes(*texts: str) -> list[str]:
    out = []
    for t in texts:
        t = _URL.sub(" ", t or "")
        for m in _CODE.finditer(t):
            c = re.sub(r"[- ]", "", m.group(1))
            if c not in out:
                out.append(c)
    return out[:10]


def safe_links(hrefs: list[str], text: str, org_domain: str | None) -> list[str]:
    """http(s) links on the sender's own organizational domain: plain ASCII
    host, no userinfo, no unusual port. Without a DMARC-aligned sender
    (org_domain None) there are none."""
    if not org_domain:
        return []
    out = []
    for raw in list(hrefs) + _URL.findall(text or ""):
        raw = raw.strip().rstrip(".,;:!?")
        if len(raw) > 400 or not raw.isascii():
            continue
        try:
            u = urllib.parse.urlsplit(raw)
            port = u.port
        except ValueError:
            continue
        host = (u.hostname or "").lower()
        if u.scheme.lower() not in ("http", "https") or not host:
            continue
        if u.username or u.password or port not in (None, 80, 443):
            continue
        if not re.fullmatch(r"[a-z0-9.-]+", host):
            continue
        if host != org_domain and not host.endswith("." + org_domain):
            continue
        link = urllib.parse.urlunsplit((u.scheme.lower(), host, u.path, u.query, ""))
        if link not in out:
            out.append(link)
    return out[:10]


def link_handles(links: list[str]) -> list[dict]:
    """What the agent sees of each link before asking for it: the host (on
    the aligned sender's own domain) and the length of the rest. The path
    and query are the sender's free text and stay out of the view."""
    out = []
    for n, link in enumerate(links, 1):
        u = urllib.parse.urlsplit(link)
        rest = u.path + ("?" + u.query if u.query else "")
        out.append({"n": n, "host": u.hostname, "path_len": len(rest)})
    return out


def _header(msg, name: str) -> str:
    try:
        return str(msg.get(name, ""))
    except Exception:  # noqa: BLE001 - undecodable header
        return ""


_RECEIVED_IP = re.compile(rb"\[([0-9a-fA-F:.]{2,45})\]\)[ \t]*\r?$")


def remote_net(raw: bytes, authserv_id: str) -> str:
    """The sending network (IPv4 /24, IPv6 /64) from Stalwart's own Received
    header, the first of the message: "from <helo> (<ptr> [<ip>])" on its
    first line. The last [address] of that line counts, so a PTR name cannot
    stand in for it; "unknown" without such a header."""
    heads = _stalwart_headers(raw)
    if not heads or heads[0][0] != b"received":
        return "unknown"
    value = heads[0][1]
    if b"by " + authserv_id.lower().encode() + b" (stalwart smtp)" not in value.lower():
        return "unknown"
    m = _RECEIVED_IP.search(value.split(b"\n", 1)[0])
    try:
        ip = ipaddress.ip_address(m.group(1).decode()) if m else None
    except ValueError:
        ip = None
    if ip is None:
        return "unknown"
    return str(ipaddress.ip_network(f"{ip}/{24 if ip.version == 4 else 64}", strict=False))


def _date(msg) -> str | None:
    try:
        return email.utils.format_datetime(email.utils.parsedate_to_datetime(_header(msg, "Date")))
    except Exception:  # noqa: BLE001
        return None


def analyze(msg, raw: bytes, authserv_id: str, psl: Psl) -> dict:
    """Everything mailgate needs from one message, computed in its worker
    process. Keys starting with "_" hold sender-chosen text and never reach
    an agent's quarantine view; the others may. `_source` is whom a
    quarantined copy counts against: the organizational domain of an
    aligned sender, else the sending network."""
    v = verdict(msg, raw, authserv_id)
    r = render(msg)
    subject = _header(msg, "Subject")
    date = _date(msg)
    org = psl.org_domain(v["from_domain"]) if v["aligned"] else None
    source = f"domain:{org}" if org else "net:" + remote_net(raw, authserv_id)
    links = safe_links(r["hrefs"], r["text"], org)
    return {
        "date": date,
        "codes": codes(subject, r["text"]),
        "links": link_handles(links),
        "subject_keywords": subject_keywords(subject),
        "attachment_count": len(r["attachments"]),
        "html": r["html"],
        "hidden": r["hidden"],
        "lenient": r["lenient"],
        "images": r["images"],
        "too_large": r["too_large"],
        "_verdict": v,
        "_subject": clean_line(subject, 200),
        "_text": r["text"],
        "_links": links,
        "_attachments": public_attachments(r["attachments"]),
        "_source": source,
    }


MAX_LINKS = 200


def all_links(hrefs: list[str], text: str) -> list[str]:
    """Every http(s) link of a rendered body once, in order: the targets of
    visible anchors, then URLs written out in the text."""
    out: list[str] = []
    for raw in list(hrefs) + _URL.findall(text or ""):
        raw = raw.strip().rstrip(".,;:!?")
        if raw and raw not in out:
            out.append(raw)
            if len(out) == MAX_LINKS:
                break
    return out


def reading(msg) -> dict:
    """An INBOX message as `mailgate read` shows it: the same rendering as
    the sanitized copy, with every link listed."""
    r = render(msg)
    return {
        "subject": clean_line(_header(msg, "Subject"), 200),
        "date": _date(msg),
        "text": r["text"],
        "links": all_links(r["hrefs"], r["text"]),
        "html": r["html"],
        "hidden": r["hidden"],
        "lenient": r["lenient"],
        "images": r["images"],
        "too_large": r["too_large"],
    }
