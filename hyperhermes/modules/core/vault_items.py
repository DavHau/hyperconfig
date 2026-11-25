"""What an agent's owner may see of its vault, shared by the broker (./vault-broker.py, for the owner
page) and root's `hermes-vault` CLI (./vault-cli.py).

The broker keeps one hermes VaultStore per home under its state directory: `home`, `profiles/<name>`,
`other/<digest>` (./vault-broker.py home_key). Owners see every item's metadata (label, kind, site,
login name, created); of a card only its brand and last 4 digits; a login's password only on an
explicit reveal, which the caller audits. Nothing else of a secret leaves through here.
"""
from __future__ import annotations

import re
from pathlib import Path

PROFILE_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
STORE_RE = re.compile(r"^(?:home|profiles/[a-z0-9][a-z0-9_-]{0,63}|other/[0-9a-f]{32})$")
ACCOUNT_RE = re.compile(r"^[A-Za-z0-9._@+-]{1,64}$")


def store_keys(state: Path) -> list[str]:
    """The stores the broker holds, in a stable order (no links followed)."""
    keys = []
    if (state / "home" / "vault").is_dir() and not (state / "home").is_symlink():
        keys.append("home")
    for parent in ("profiles", "other"):
        d = state / parent
        if not d.is_dir() or d.is_symlink():
            continue
        for p in sorted(d.iterdir()):
            key = f"{parent}/{p.name}"
            if STORE_RE.match(key) and not p.is_symlink() and (p / "vault").is_dir():
                keys.append(key)
    return keys


def store_title(key: str) -> str:
    if key == "home":
        return "main profile"
    if key.startswith("profiles/"):
        return f"profile {key.split('/', 1)[1]}"
    return "other home"


def card_brand(number: str) -> str:
    n = re.sub(r"\D", "", number or "")
    if n.startswith("4"):
        return "Visa"
    if n[:2] in ("34", "37"):
        return "American Express"
    if n[:2] in {str(i) for i in range(51, 56)} or (n[:4].isdigit() and 2221 <= int(n[:4] or 0) <= 2720):
        return "Mastercard"
    if n.startswith("6011") or n.startswith("65") or n[:3] in {str(i) for i in range(644, 650)}:
        return "Discover"
    if n[:2] == "35":
        return "JCB"
    if n[:2] in ("30", "36", "38"):
        return "Diners Club"
    if n[:2] == "62":
        return "UnionPay"
    return "Card"


def last4(number: str) -> str:
    digits = re.sub(r"\D", "", number or "")
    return digits[-4:] if len(digits) >= 8 else ""


def printable(value: object, cap: int = 200) -> str:
    """An agent-written field for the owner's eyes (page and CLI): valid UTF-8 (a lone surrogate
    would fail the whole page or listing), no control byte (no terminal escape), no bidi or
    zero-width character (no reordered or hidden text), capped."""
    s = str(value if value is not None else "").encode("utf-8", "replace").decode("utf-8")
    return re.sub(r"[\x00-\x1f\x7f-\x9f\u200b-\u200f\u2028-\u202e\u2066-\u2069\ufeff]", "?", s)[:cap]


def owner_view(meta: dict, record: dict) -> dict:
    """An item as its owner's list shows it: metadata, plus a card's brand and last 4. Never a
    password, a full card number, a CVC, an expiry, an address field or a TOTP seed."""
    out = {k: (meta[k] if isinstance(meta[k], bool) else printable(meta[k]))
           for k in ("id", "kind", "label", "origin", "created_at", "identifier",
                     "identifier_type", "has_otp") if meta.get(k) is not None}
    if meta.get("kind") == "payment":
        number = str((record.get("secret") or {}).get("card_number") or "")
        out["brand"], out["last4"] = card_brand(number), last4(number)
    return out


def safe(s: object) -> str:
    """A field for a journal line: no space or control byte, so no field forges an audit line."""
    return re.sub(r"[^A-Za-z0-9._@+/-]", "?", str(s))[:80]


def audit_line(action: str, item_id: str, kind: str, store: str, account: str, via: str) -> str:
    """The one audit line per owner reveal or delete (page and CLI alike): ids only, no values."""
    return (f"owner-{action} {safe(item_id)} kind={safe(kind)} store={safe(store)} "
            f"account={safe(account)} via={safe(via)}")
