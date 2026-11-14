"""Print one raw IPP request to stdout (for curl --data-binary @-).

The VM test (./test.nix) posts these from a LAN client to the server's
shared queue and checks the HTTP status cupsd answers with: 403 for ops
the `lan` policy (../home-printer-host.nix) keeps on localhost, never 401.

  ipp_req.py <op-hex> <printer-uri> [job-id] [notify-uri]
"""
import struct
import sys


def attr(tag, name, value):
    if isinstance(value, int):
        v = struct.pack(">i", value)
    else:
        v = value.encode()
    n = name.encode()
    return struct.pack(">bH", tag, len(n)) + n + struct.pack(">H", len(v)) + v


op = int(sys.argv[1], 16)
uri = sys.argv[2]
body = struct.pack(">bbHi", 2, 0, op, 1) + b"\x01"
body += attr(0x47, "attributes-charset", "utf-8")
body += attr(0x48, "attributes-natural-language", "en")
body += attr(0x45, "printer-uri", uri)
# The share is unauthenticated: claim to be root.
body += attr(0x42, "requesting-user-name", "root")
if len(sys.argv) > 3 and sys.argv[3]:
    body += attr(0x21, "job-id", int(sys.argv[3]))
    body += attr(0x21, "document-number", 1)
if len(sys.argv) > 4:
    body += b"\x06"
    body += attr(0x45, "notify-recipient-uri", sys.argv[4])
    body += attr(0x44, "notify-events", "all")
body += b"\x03"
sys.stdout.buffer.write(body)
