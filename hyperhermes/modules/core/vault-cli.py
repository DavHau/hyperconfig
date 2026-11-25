"""hermes-vault: root's look into an agent's vault, read the way its broker reads it (./vault-broker.nix).

usage: hermes-vault <agent> [--profile P] list
       hermes-vault <agent> [--profile P] show <label-or-id>

`list`: every item of the agent's main vault (or profile P's): id, kind, label, site, login name,
created; a card's brand and last 4 digits. `show`: a login's name and password; of a card only its
brand and last 4 digits. Every `show` of a login writes the owner page's audit line (ids, no values)
to the journal under the broker's identifier, as root: `journalctl -t hermes-vault-<agent> _UID=0`
(any uid may log under a tag; the _UID field is the kernel's).

Root only. Reads hermes' VaultStore(direct=True) on /var/lib/private/hermes-vault/<agent>/...; never
creates a file there (a root-owned key or lock would lock the broker out): a store without
ciphertext is empty.
"""
from __future__ import annotations

import atexit
import os
import shutil
import sys
import syslog
import tempfile
from pathlib import Path

ROOT = Path(os.environ.get("HERMES_VAULT_STATE_ROOT", "/var/lib/private/hermes-vault"))
AGENT_RE_CHARS = set("abcdefghijklmnopqrstuvwxyz0123456789-_")
USAGE = "usage: hermes-vault <agent> [--profile P] list | show <label-or-id>"


sys.path.insert(0, str(Path(__file__).resolve().parent))
import vault_items  # noqa: E402


def clean(value: object, cap: int = 200) -> str:
    """An agent-written field, printed to root's terminal: no control bytes (no ESC/OSC sequence
    that writes the clipboard or rewrites the screen), valid UTF-8, capped (vault_items.printable)."""
    return vault_items.printable(value, cap)


def fail(msg: str, code: int = 1) -> None:
    print(f"hermes-vault: {msg}", file=sys.stderr)
    sys.exit(code)


def main(argv: list[str]) -> None:
    if os.geteuid() != 0:
        fail("root only", 77)
    args = list(argv)
    profile = None
    if "--profile" in args:
        i = args.index("--profile")
        if i + 1 >= len(args):
            fail(USAGE, 64)
        profile = args[i + 1]
        del args[i:i + 2]
    if len(args) < 2 or args[1] not in ("list", "show") or (args[1] == "show") != (len(args) == 3):
        fail(USAGE, 64)
    agent, cmd = args[0], args[1]
    if not agent or set(agent) - AGENT_RE_CHARS:
        fail("bad agent name", 64)

    if profile is not None and not vault_items.PROFILE_RE.match(profile):
        fail("bad profile name", 64)
    key = "home" if profile is None else f"profiles/{profile}"
    base = ROOT / agent / key / "vault"
    if not (ROOT / agent).is_dir():
        fail(f"no vault broker state for {agent!r} on this host")
    # hermes reads $HERMES_HOME/config.yaml for new keys only; an empty home, as the broker's
    home = tempfile.mkdtemp(prefix="hermes-vault-")
    atexit.register(shutil.rmtree, home, True)
    for name in [n for n in os.environ if n.startswith("HERMES_")]:  # root's HERMES_UID & co. would
        del os.environ[name]  # make hermes chown/chmod the broker's store
    os.environ["HERMES_HOME"] = home
    from agent.vault_store import VaultStore

    records: list[dict] = []
    if (base / "vault.json.enc").is_file() and (base / "vault.key").is_file() and (base / ".vault.lock").is_file():
        store = VaultStore(base_dir=base, direct=True)
        with store._locked():
            records = store._read_all()
    elif cmd == "list":
        others = ", ".join(k for k in vault_items.store_keys(ROOT / agent) if k != key)
        print(f"(no items in {vault_items.store_title(key)}{'; also: ' + others if others else ''})")
        return

    def view(rec: dict) -> dict:
        meta = VaultStore._meta(rec)
        return vault_items.owner_view(meta.to_dict() | {"identifier_type": meta.identifier_type}, rec)

    if cmd == "list":
        for rec in records:
            v = view(rec)
            extra = (f"{v.get('brand')} ****{v.get('last4')}" if v.get("kind") == "payment"
                     else v.get("identifier") or "")
            print("\t".join(clean(x) for x in (v.get("id"), v.get("kind"), v.get("label"), v.get("origin") or "-",
                                              extra or "-", (v.get("created_at") or "")[:10])))
        return

    wanted = args[2]
    hits = [r for r in records if r.get("id") == wanted] or [r for r in records if r.get("label") == wanted]
    if not hits:
        hits = [r for r in records if wanted.lower() in str(r.get("label", "")).lower()]
    if not hits:
        fail(f"no item {clean(wanted)!r} in {vault_items.store_title(key)} of {agent}")
    if len(hits) > 1:
        print("several items match; give the id:", file=sys.stderr)
        for r in hits:
            print(f"  {clean(r.get('id'))}\t{clean(r.get('kind'))}\t{clean(r.get('label'))}", file=sys.stderr)
        sys.exit(2)
    rec = hits[0]
    v = view(rec)
    if v["kind"] == "login":  # the only kind whose secret `show` prints
        user = os.environ.get("SUDO_USER") or "root"
        syslog.openlog(f"hermes-vault-{agent}", 0, syslog.LOG_AUTH)
        syslog.syslog(syslog.LOG_NOTICE, vault_items.audit_line("reveal", v["id"], v["kind"], key, user, "cli"))
    print(f"label:    {clean(v.get('label'))}")
    print(f"kind:     {clean(v.get('kind'))}")
    print(f"site:     {clean(v.get('origin') or 'any site')}")
    if v["kind"] == "login":
        print(f"{clean(v.get('identifier_type') or 'login', 20) + ':':9} {clean(v.get('identifier'))}")
        print(f"password: {clean((rec.get('secret') or {}).get('password'), 4096)}")
    elif v["kind"] == "payment":
        print(f"card:     {clean(v.get('brand'), 40)} ****{clean(v.get('last4'), 4)} (the full number is never shown)")
    else:
        print("(address fields are not shown)")


if __name__ == "__main__":
    main(sys.argv[1:])
