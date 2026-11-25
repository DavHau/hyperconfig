"""Stand-in owner vault page for the vault-broker check (./default.nix): runs as the main process of
the unit the broker names in BROKER_OWNER_UNIT (a dynamic user, as the real page), lists the vault,
reveals every item, and has a child of its own try a reveal too. Prints one JSON line to the
journal: per item its kind and the digest of what a reveal gave (or the refusal). Never a value.
"""
import hashlib
import json
import socket
import subprocess
import sys
import time

SOCK = "/run/hermes-vault/alice.sock"


def call(req):
    s = socket.socket(socket.AF_UNIX)
    s.connect(SOCK)
    s.sendall(json.dumps(req).encode() + b"\n")
    s.shutdown(socket.SHUT_WR)
    data = b""
    while chunk := s.recv(65536):
        data += chunk
    return json.loads(data)


if sys.argv[1:] == ["child"]:
    print(json.dumps(call(json.loads(sys.stdin.read()))))
    sys.exit(0)

out = {"items": {}}
listed = call({"op": "owner_list", "account": "alice"})
out["list_ok"] = listed["ok"]
out["list"] = listed.get("result") if listed["ok"] else listed
for store in listed.get("result") or []:
    for item in store["items"]:
        r = call({"op": "owner_reveal", "account": "alice", "store": store["store"], "item_id": item["id"]})
        if r["ok"]:
            out["items"][item["id"]] = {"ok": True, "identifier": r["result"].get("identifier"),
                                        "password": hashlib.sha256(r["result"]["password"].encode()).hexdigest()}
        else:
            out["items"][item["id"]] = {"ok": False, "error": r["error"]}
        if store["store"] == "home" and item["kind"] == "login":
            child = subprocess.run([sys.executable, __file__, "child"], capture_output=True, text=True,
                                   input=json.dumps({"op": "owner_reveal", "account": "alice",
                                                     "store": "home", "item_id": item["id"]}))
            out["child"] = json.loads(child.stdout)
out["no_account"] = call({"op": "owner_list"})
# the hourly cap (the check sets 2): one reveal so far, so one more passes and the next is refused
home_login = next(i["id"] for st in listed.get("result") or [] if st["store"] == "home"
                  for i in st["items"] if i["kind"] == "login")
out["again"] = [call({"op": "owner_reveal", "account": "alice", "store": "home", "item_id": home_login})
                for _ in range(2)]
for r in out["again"]:
    r.pop("result", None)
print("RESULT " + json.dumps(out), flush=True)
while True:
    time.sleep(3600)
