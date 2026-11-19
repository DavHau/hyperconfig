"""residential-proxy: som's loopback forward proxy to Evomi's residential gateway.

Clients (som's hermes agents, their Camofox servers, searx) speak plain
HTTP proxy to LISTEN (CONNECT for https, absolute-URI requests for http).
Who may connect is nftables' call (./default.nix: an owner-uid gate on the
port); this process holds the Evomi credentials, which no client sees.

Targeting rides the proxy username the client sends (Proxy-Authorization
basic, any password or none), validated strictly so nothing but these two
parameters reaches Evomi's password DSL:
    ""            -> the default country (DEFAULT_COUNTRY)
    "sg"          -> country SG
    "us-session-ab12cd34"  -> country US, sticky session ab12cd34 (6-10
                     alphanumerics; Evomi keeps the IP ~30 min)
    "session-ab12cd34"     -> default country, sticky session
Upstream is Evomi's TLS proxy endpoint (the credentials never cross the
Mullvad exit in clear text); every client request becomes one CONNECT
there. When Evomi refuses, the client gets a 402 (traffic used up or
account suspended) or a 502 (anything else) whose reason phrase and body
say so; Evomi's own answer text is never relayed, and logged only with the
credentials redacted.

Targets are refused (403) before anything reaches Evomi unless they are a
public name or a global IP literal (any spelling a resolver accepts:
hex/decimal/octal IPv4, IPv4-mapped IPv6), on port 80 or 443: no
loopback, private, link-local, CGNAT, mesh, NAT64 or multicast addresses,
no single-label, numeric or internal names (.local, .internal, .lan,
.home, .arpa, .d, .onion) and no home-router names (fritz.box, ...). The gateway does not resolve names itself: Evomi resolves
them on its side, so a local answer would prove nothing; a public name
pointing at a private address (rebinding) can only be stopped by Evomi.

Usage: gateway.py  (config from the environment, credentials from
$CREDENTIALS_DIRECTORY/{user,password}).
"""

import asyncio
import base64
import ipaddress
import logging
import os
import re
import socket
import ssl
import sys

LISTEN_HOST = os.environ.get("LISTEN_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8897"))
UPSTREAM_HOST = os.environ.get("UPSTREAM_HOST", "rp.evomi-proxy.com")
UPSTREAM_PORT = int(os.environ.get("UPSTREAM_PORT", "1001"))
UPSTREAM_TLS = os.environ.get("UPSTREAM_TLS", "1") == "1"
UPSTREAM_CA = os.environ.get("UPSTREAM_CA")  # tests only
DEFAULT_COUNTRY = os.environ.get("DEFAULT_COUNTRY", "SG").upper()
ALLOWED_PORTS = {int(p) for p in os.environ.get("ALLOWED_PORTS", "80 443").split()}
MAX_CLIENTS = int(os.environ.get("MAX_CLIENTS", "512"))  # per uid: ./service.nix (nft)
IDLE_TIMEOUT = 300
HEAD_LIMIT = 64 * 1024

log = logging.getLogger("residential-proxy")

TARGET = re.compile(r"(?P<cc>[A-Za-z]{2})(?:-session-(?P<s1>[A-Za-z0-9]{6,10}))?|session-(?P<s2>[A-Za-z0-9]{6,10})")
HOST = re.compile(r"[A-Za-z0-9.-]{1,253}|\[[0-9A-Fa-f:.]{2,45}\]")
PORT = re.compile(r"[0-9]{1,5}")
# Request line and header values: no control characters (no lone CR, LF
# or NUL to smuggle a second request or header past this parser); obs-text
# (0x80-0xff, RFC 9110) stays legal.
FIELD = re.compile(r"[\t\x20-\x7e\x80-\xff]*")
INTERNAL_SUFFIXES = (".localhost", ".local", ".internal", ".lan", ".home", ".arpa", ".d", ".onion")
# Ranges Python counts as global but that are not a public host's address.
NOT_PUBLIC = [ipaddress.ip_network(n) for n in (
    "::/96",           # IPv4-compatible (deprecated): an IPv4 address in disguise
    "64:ff9b::/96",    # NAT64 well-known prefix
    "200::/7",         # Yggdrasil mesh
    "::ffff:0:0:0/96", # IPv4-translated (SIIT)
    "fec0::/10",       # site-local (deprecated, still routed on some LANs)
)]
# Names home routers answer for themselves (the exit's LAN).
ROUTER_NAMES = ("fritz.box", "speedport.ip", "routerlogin.net", "routerlogin.com", "tplinkwifi.net",
                "tplinklogin.net", "tplinkmodem.net", "mywifiext.net", "router.asus.com")


def read_credential(name):
    with open(os.path.join(os.environ["CREDENTIALS_DIRECTORY"], name)) as f:
        return f.read().strip()


EVOMI_USER = read_credential("user")
EVOMI_PASSWORD = read_credential("password")
if not re.fullmatch(r"[^\s:]+", EVOMI_USER) or not re.fullmatch(r"\S+", EVOMI_PASSWORD):
    sys.exit("residential-proxy: the Evomi credentials have an unexpected shape")


class Refusal(Exception):
    def __init__(self, status, reason, detail):
        super().__init__(detail)
        self.status, self.reason, self.detail = status, reason, detail


USAGE = ("proxy username picks the exit: 'default', '<cc>', '<cc>-session-<id>' or 'session-<id>' "
         "(cc: two-letter country code; id: 6-10 letters/digits); any password")


def parse_target(headers):
    """(country, session) from the client's Proxy-Authorization username.

    No Proxy-Authorization at all answers 407 with a Basic challenge:
    browsers (Firefox, Chromium) send proxy credentials only then."""
    auth = headers.get("proxy-authorization", "")
    if not auth:
        raise Refusal(407, "Proxy Authentication Required", USAGE)
    scheme, _, value = auth.partition(" ")
    if scheme.lower() != "basic":
        raise Refusal(400, "Bad Request", USAGE)
    try:
        user = base64.b64decode(value.strip(), validate=True).decode("ascii").partition(":")[0]
    except (ValueError, UnicodeDecodeError):
        raise Refusal(400, "Bad Request", USAGE)
    if user in ("", "default"):
        return DEFAULT_COUNTRY, None
    m = TARGET.fullmatch(user)
    if m is None:
        raise Refusal(400, "Bad Request", f"{user!r}: {USAGE}")
    cc = m.group("cc") or DEFAULT_COUNTRY
    return cc.upper(), m.group("s1") or m.group("s2")


def evomi_auth(country, session):
    password = f"{EVOMI_PASSWORD}_country-{country}"
    if session:
        password += f"_session-{session}"
    token = base64.b64encode(f"{EVOMI_USER}:{password}".encode()).decode()
    return f"Basic {token}"


async def read_head(reader):
    head = await reader.readuntil(b"\r\n\r\n")
    if len(head) > HEAD_LIMIT:
        raise ValueError("head too large")
    lines = head.decode("latin-1").split("\r\n")
    method, target, version = lines[0].split(" ", 2)
    headers = {}
    raw = []
    for line in lines[1:]:
        if not line:
            continue
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
        raw.append((name.strip(), value.strip()))
    return method, target, version, headers, raw


def check_target(host):
    """The host as it goes to the provider (IP literals canonical), or a 403."""
    h = (host[1:-1] if host.startswith("[") else host).rstrip(".").lower()
    ip = None
    try:
        ip = ipaddress.ip_address(h)
    except ValueError:
        try:  # 0x7f000001, 2130706433, 0177.0.0.1, 127.1: what resolvers accept
            ip = ipaddress.IPv4Address(socket.inet_aton(h))
        except OSError:
            pass
    if ip is not None:
        if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
            ip = ip.ipv4_mapped
        if not ip.is_global or ip.is_multicast or any(ip in n for n in NOT_PUBLIC if n.version == ip.version):
            raise Refusal(403, "Target Not Allowed", f"residential proxy: {host} is not a public address")
        return f"[{ip}]" if ip.version == 6 else str(ip)
    # a numeric last label is never a public name (10.0.0.08: some stacks
    # read it as an address)
    last = h.rsplit(".", 1)[-1]
    if ("." not in h or h.endswith(INTERNAL_SUFFIXES) or re.fullmatch(r"[0-9]+|0x[0-9a-f]*", last)
            or any(h == n or h.endswith("." + n) for n in ROUTER_NAMES)):
        raise Refusal(403, "Target Not Allowed", f"residential proxy: {host} is not a public name")
    return h


def split_hostport(text, default_port):
    host, port = text, default_port
    if text.startswith("["):
        end = text.find("]")
        host, rest = text[: end + 1], text[end + 1 :]
        if rest.startswith(":"):
            port = rest[1:]
        elif rest:
            port = "x"  # junk after ']': a 400
    elif text.count(":") == 1:
        host, port = text.split(":")
    if not HOST.fullmatch(host) or not PORT.fullmatch(str(port)):
        raise Refusal(400, "Bad Request", f"not a host:port: {text!r}")
    return check_target(host), int(port)


async def upstream_connect(host, port, country, session):
    """A tunnel through Evomi to host:port, or Refusal saying why not."""
    ctx = None
    if UPSTREAM_TLS:
        ctx = ssl.create_default_context(cafile=UPSTREAM_CA) if UPSTREAM_CA else ssl.create_default_context()
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(UPSTREAM_HOST, UPSTREAM_PORT, ssl=ctx,
                                    server_hostname=UPSTREAM_HOST if ctx else None),
            20,
        )
    except (OSError, asyncio.TimeoutError, ssl.SSLError) as exc:
        raise Refusal(502, "Residential Proxy Unreachable",
                      f"residential proxy: cannot reach the provider ({type(exc).__name__}); "
                      "try again later or go without the residential proxy")
    target = f"{host}:{port}"
    writer.write((f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n"
                  f"Proxy-Authorization: {evomi_auth(country, session)}\r\n\r\n").encode("latin-1"))
    await writer.drain()
    try:
        head = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 40)
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError, OSError):
        writer.close()
        raise Refusal(502, "Residential Proxy Failed", "residential proxy: the provider closed the connection without an answer")
    status_line = head.split(b"\r\n", 1)[0].decode("latin-1", "replace")
    parts = status_line.split(" ", 2)
    code = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
    if code == 200:
        return reader, writer
    body = b""
    try:
        body = await asyncio.wait_for(reader.read(512), 3)
    except (asyncio.TimeoutError, OSError):
        pass
    writer.close()
    text = body.decode("latin-1", "replace")
    for secret in (EVOMI_PASSWORD, EVOMI_USER):  # before sanitising, so any secret matches
        text = text.replace(secret, "<redacted>")
    text = re.sub(r"[^\x20-\x7e]", " ", text).strip()[:200]
    log.warning("upstream refused CONNECT (country %s): %s %s", country, code, text)
    if code in (402, 407):
        raise Refusal(402, "Residential Proxy Out Of Service",
                      f"residential proxy: the provider refused the request (HTTP {code}): the paid traffic is "
                      "probably used up or the account was suspended. Do not retry; go without the "
                      "residential proxy and tell the user.")
    raise Refusal(502, "Residential Proxy Refused",
                  f"residential proxy: the provider could not open {target} via {country} (HTTP {code}). "
                  "Try another country or later.")


async def pipe(reader, writer):
    try:
        while True:
            data = await asyncio.wait_for(reader.read(65536), IDLE_TIMEOUT)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (OSError, asyncio.TimeoutError, asyncio.IncompleteReadError):
        pass
    finally:
        try:
            writer.close()
        except OSError:
            pass


def refuse(writer, r):
    body = (r.detail + "\n").encode()
    challenge = 'Proxy-Authenticate: Basic realm="residential"\r\n' if r.status == 407 else ""
    writer.write((f"HTTP/1.1 {r.status} {r.reason}\r\nContent-Type: text/plain\r\n{challenge}"
                  f"X-Residential-Proxy-Error: {r.reason}\r\n"
                  f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode("latin-1") + body)


clients = 0


async def handle(reader, writer):
    global clients
    if clients >= MAX_CLIENTS:
        refuse(writer, Refusal(503, "Busy", "residential proxy: too many connections"))
        writer.close()
        return
    clients += 1
    try:
        try:
            method, target, version, headers, raw = await asyncio.wait_for(read_head(reader), 30)
        except (ValueError, asyncio.IncompleteReadError, asyncio.LimitOverrunError, asyncio.TimeoutError, OSError):
            writer.close()
            return
        try:
            if not FIELD.fullmatch(f"{method} {target} {version}") or not all(FIELD.fullmatch(n + v) for n, v in raw):
                raise Refusal(400, "Bad Request", "residential proxy: control characters in the request")
            country, session = parse_target(headers)
            if method == "CONNECT":
                host, port = split_hostport(target, 443)
                request = None
            else:
                if not target.startswith("http://"):
                    raise Refusal(400, "Bad Request", "absolute http:// URI or CONNECT expected")
                rest = target[len("http://"):]
                authority, slash, path = rest.partition("/")
                host, port = split_hostport(authority, 80)
                kept = [(n, v) for n, v in raw if n.lower() not in
                        ("proxy-authorization", "proxy-connection", "connection", "keep-alive")]
                request = (f"{method} /{path} {version}\r\n" + "".join(f"{n}: {v}\r\n" for n, v in kept)
                           + "Connection: close\r\n\r\n").encode("latin-1")
            if port not in ALLOWED_PORTS:
                raise Refusal(403, "Port Not Allowed", f"residential proxy: port {port} is not allowed")
            up_reader, up_writer = await upstream_connect(host, port, country, session)
        except Refusal as r:
            refuse(writer, r)
            await writer.drain()
            writer.close()
            return
        if request is None:
            writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
            await writer.drain()
        else:
            up_writer.write(request)
            await up_writer.drain()
        await asyncio.gather(pipe(reader, up_writer), pipe(up_reader, writer))
    finally:
        clients -= 1


async def main():
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    server = await asyncio.start_server(handle, LISTEN_HOST, LISTEN_PORT, limit=HEAD_LIMIT)
    log.info("listening on %s:%d, upstream %s:%d, default country %s",
             LISTEN_HOST, LISTEN_PORT, UPSTREAM_HOST, UPSTREAM_PORT, DEFAULT_COUNTRY)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
