"""A stand-in for Evomi's TLS proxy endpoint (./test.nix): CONNECT and
absolute-URI requests, Basic auth `evomi-user:evomi-pass_country-XX[_session-ID]`.
Logs `<client address> <country> <session> <target>` per accepted request to
/tmp/provider.log; answers 402 for every request while /tmp/exhausted exists
(the traffic used up), 407 for wrong credentials, and a 403 naming the
credentials for echo.example."""
import asyncio
import base64
import os
import re
import ssl
import sys

CERT, KEY, HOST, PORT = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
AUTH = re.compile(r"evomi-user:evomi-pass_country-([A-Z]{2})(?:_session-([A-Za-z0-9]{6,10}))?")


async def pipe(r, w):
    try:
        while data := await r.read(65536):
            w.write(data)
            await w.drain()
    except OSError:
        pass
    finally:
        w.close()


def answer(w, status, text):
    w.write(f"HTTP/1.1 {status} {text}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode())


async def handle(reader, writer):
    peer = writer.get_extra_info("peername")[0]
    try:
        head = (await reader.readuntil(b"\r\n\r\n")).decode("latin-1")
    except Exception:
        writer.close()
        return
    lines = head.split("\r\n")
    method, target, _ = lines[0].split(" ", 2)
    headers = {l.split(":", 1)[0].strip().lower(): l.split(":", 1)[1].strip() for l in lines[1:] if ":" in l}
    if os.path.exists("/tmp/exhausted"):
        answer(writer, 402, "Payment Required")
        writer.close()
        return
    auth = headers.get("proxy-authorization", "")
    creds = base64.b64decode(auth[6:]).decode() if auth.startswith("Basic ") else ""
    m = AUTH.fullmatch(creds)
    if not m:
        answer(writer, 407, "Proxy Authentication Required")
        writer.close()
        return
    if method != "CONNECT":
        answer(writer, 400, "CONNECT only")
        writer.close()
        return
    host, port = target.rsplit(":", 1)
    if host == "echo.example":  # a refusal whose text names the account
        body = f"refused for {creds}".encode()
        writer.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(body) + body)
        await writer.drain()
        writer.close()
        return
    with open("/tmp/provider.log", "a") as f:
        f.write(f"{peer} {m.group(1)} {m.group(2) or '-'} {target}\n")
    try:
        ur, uw = await asyncio.open_connection(host, int(port))
    except OSError:
        answer(writer, 502, "Bad Gateway")
        writer.close()
        return
    writer.write(b"HTTP/1.1 200 Connection established\r\n\r\n")
    await writer.drain()
    await asyncio.gather(pipe(reader, uw), pipe(ur, writer))


async def main():
    ctx = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    ctx.load_cert_chain(CERT, KEY)
    server = await asyncio.start_server(handle, HOST, PORT, ssl=ctx)
    async with server:
        await server.serve_forever()


asyncio.run(main())
