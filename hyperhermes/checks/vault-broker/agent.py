"""The agent's side of the vault-broker check (./default.nix): what a terminal command or script of
the agent's uid can do with hermes' own VaultStore. Prints one JSON line.

  agent.py legacy <home> <kind> <label>   write a LEGACY file vault item (VaultStore(direct=True), as
                                          hermes before the broker did), print its id
  agent.py list <home>                    the items (metadata), through the broker
  agent.py add <home>                     add a test card through the broker, print its id
  agent.py resolve <home> <id>            try to read the values: must be refused
  agent.py remove <home> <id>
  agent.py raw <socket> <json>            a raw request on a socket, print the reply
"""
import json
import socket
import sys
from pathlib import Path

from agent.vault_store import VaultError, VaultStore

CARD = {"card_number": "4111111111111111", "exp_month": "12", "exp_year": "2031", "cvc": "737"}
LOGIN = {"identifier_type": "username", "identifier": "alice", "password": "s3cret-legacy-pw"}

cmd, *args = sys.argv[1:]
if cmd == "raw":
    s = socket.socket(socket.AF_UNIX)
    s.connect(args[0])
    s.sendall(args[1].encode() + b"\n")
    s.shutdown(socket.SHUT_WR)
    data = b""
    while chunk := s.recv(65536):
        data += chunk
    print(data.decode())
    sys.exit(0)
home = Path(args[0])
if cmd == "legacy":
    store = VaultStore(base_dir=home / "vault", direct=True)
    kind, label = args[1], args[2]
    meta = (store.add_item("login", label, dict(LOGIN), origin="https://shop.example.com")
            if kind == "login" else store.add_item(kind, label, dict(CARD)))
    print(json.dumps({"id": meta.id}))
    sys.exit(0)
store = VaultStore(base_dir=home / "vault")
try:
    if cmd == "list":
        print(json.dumps([m.to_dict() for m in store.list_items()]))
    elif cmd == "add":
        print(json.dumps({"id": store.add_item("payment", "added card", dict(CARD)).id}))
    elif cmd == "resolve":
        secret = store.resolve_secret(args[1])
        print(json.dumps({"LEAKED": bool(secret)}))
    elif cmd == "remove":
        print(json.dumps({"removed": store.remove_item(args[1])}))
except VaultError as exc:
    print(json.dumps({"error": str(exc)}))
