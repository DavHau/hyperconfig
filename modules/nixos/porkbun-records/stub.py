# A stand-in for porkbun's JSON API v3, for the VM tests: the four dns/
# endpoints ./sync.sh uses, on an in-memory zone. Keys must be "test-key" /
# "test-secret". Test hooks (GET): /_records (the zone), /_writes (every
# write call so far, one per line), /_fail/error and /_fail/garbage (every
# API call answers an error status / a non-JSON page), /_fail/off.
#
#   stub.py <port> <seed.json>    seed: [{name, type, content}]
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

records = []
writes = []
fail = "off"
next_id = 1


def add(name, rtype, content, ttl="600"):
    global next_id
    records.append({"id": str(next_id), "name": name, "type": rtype, "content": content, "ttl": ttl})
    next_id += 1


def fqdn(zone, sub):
    return f"{sub}.{zone}" if sub else zone


class Handler(BaseHTTPRequestHandler):
    def answer(self, code, body, ctype="application/json"):
        data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        global fail
        if self.path == "/_records":
            return self.answer(200, records)
        if self.path == "/_writes":
            return self.answer(200, "".join(w + "\n" for w in writes), "text/plain")
        if self.path.startswith("/_fail/"):
            fail = self.path.split("/")[2]
            return self.answer(200, {"fail": fail})
        self.answer(404, {"status": "ERROR", "message": "not found"})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])) or b"{}")
        if fail == "error":
            return self.answer(400, {"status": "ERROR", "message": "stub says no"})
        if fail == "garbage":
            return self.answer(200, "<html>maintenance</html>", "text/html")
        if body.get("apikey") != "test-key" or body.get("secretapikey") != "test-secret":
            return self.answer(400, {"status": "ERROR", "message": "Invalid API key."})
        parts = self.path.split("/")
        # /api/json/v3/dns/<op>/<zone>[/<type>/<sub>]
        if parts[1:5] != ["api", "json", "v3", "dns"]:
            return self.answer(404, {"status": "ERROR", "message": "not found"})
        op, rest = parts[5], parts[6:]
        if op == "create":
            add(fqdn(rest[0], body["name"]), body["type"], body["content"], body.get("ttl", "600"))
            writes.append(f"create {fqdn(rest[0], body['name'])} {body['type']} {body['content']}")
            return self.answer(200, {"status": "SUCCESS", "id": next_id - 1})
        zone, rtype, sub = rest[0], rest[1], rest[2] if len(rest) > 2 else ""
        name = fqdn(zone, sub)
        match = [r for r in records if r["name"] == name and r["type"] == rtype]
        if op == "retrieveByNameType":
            return self.answer(200, {"status": "SUCCESS", "records": match})
        if op == "editByNameType":
            for r in match:
                r["content"] = body["content"]
                r["ttl"] = body.get("ttl", r["ttl"])
            writes.append(f"edit {name} {rtype} {body['content']}")
            return self.answer(200, {"status": "SUCCESS"})
        if op == "deleteByNameType":
            records[:] = [r for r in records if r not in match]
            writes.append(f"delete {name} {rtype}")
            return self.answer(200, {"status": "SUCCESS"})
        self.answer(404, {"status": "ERROR", "message": "unknown endpoint"})


with open(sys.argv[2]) as f:
    for r in json.load(f):
        add(r["name"], r["type"], r["content"])
HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
