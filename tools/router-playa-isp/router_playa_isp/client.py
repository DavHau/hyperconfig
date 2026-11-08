"""HTTP client for the Livebox Fibra (Arcadyan PRV3399B) web UI. See ../PROTOCOL.md."""

import hashlib
import http.client
import re
import time
import urllib.parse
from dataclasses import dataclass

LAN_PAGE = "advanced_network_configuration.htm"
LAN_CGI = "cgi/cgi_lan.js"
DMZ_CGI = "cgi/cgi_fw_dmz.js"
MAX_RESERVATIONS = 32  # MAX_DHCP_REV_NUM in cgi_lan.js
TIMEOUT = 20
APPLY_SETTLE = 3  # seconds the UI waits after a reservation change

ADD_CFG = re.compile(r"""addCfg\("([^"]+)",(\d+),'([^']*)'\);""")
PI = re.compile(r'<meta name="pi" content="([^"]+)">')
URN = re.compile(r"new_urn = '([0-9a-f]+)'")
LOGGED_IN = re.compile(r"bUsrisLogined = parseInt\('0'\+'(-?\d+)'\)")
LEASE = re.compile(r"\{ip:'([^']*)',mac:'([^']*)',hostname:'([^']*)',uni:'([^']*)',leaseTime:'([^']*)',createdTime:'([^']*)'\}")


class RouterError(Exception):
    pass


def unescape(s: str) -> str:
    """The UI's arc.str.unescape: JS unescape() twice."""
    return urllib.parse.unquote(urllib.parse.unquote(s))


def escape(s: str) -> str:
    """The UI's arc.str.escape: every byte but [0-9A-Za-z] as %XX (upper-case hex)."""
    if any(ord(c) > 0xFF for c in s):
        raise RouterError(f"{s!r}: the router's escaping only covers Latin-1")
    return "".join(c if c.isascii() and c.isalnum() else f"%{ord(c):02X}" for c in s)


@dataclass(frozen=True)
class Cfg:
    id: int  # per-session id the UI posts the setting under
    value: str  # unescaped


@dataclass(frozen=True)
class Reservation:
    slot: int  # 1..32: lan_dhcp_reserved_client_1<slot>
    ip: str
    mac: str  # upper-case
    name: str


@dataclass(frozen=True)
class Lease:
    ip: str
    mac: str
    hostname: str
    interface: str
    lease_time: str


@dataclass(frozen=True)
class LanState:
    pi: str  # the LAN page's form token, posted with every change
    cfg: dict[str, Cfg]  # every addCfg of cgi_lan.js (+ cgi_fw_dmz.js)
    reservations: list[Reservation]  # occupied slots, by slot
    leases: list[Lease]

    def value(self, name: str) -> str:
        return self.cfg[name].value

    def slot_name(self, slot: int) -> str:
        return f"lan_dhcp_reserved_client_1{slot}"

    def free_slots(self) -> list[int]:
        used = {r.slot for r in self.reservations}
        return [s for s in range(1, MAX_RESERVATIONS + 1) if s not in used]

    def snapshot(self) -> dict:
        """JSON-able read-out (values only: the ids change per session)."""
        return {
            "cfg": {k: v.value for k, v in self.cfg.items()},
            "reservations": [r.__dict__ for r in self.reservations],
            "leases": [l.__dict__ for l in self.leases],
        }


def parse_reservation(slot: int, value: str) -> Reservation | None:
    if not value:
        return None
    parts = value.split(",")
    if len(parts) != 3:
        raise RouterError(f"reservation slot {slot}: unexpected value {value!r}")
    ip, mac, name = parts
    return Reservation(slot, ip, mac.upper(), name)


class Router:
    """One web session. Use as a context manager: it logs out at the end."""

    def __init__(self, host: str, user: str, password: str):
        self.host = host
        self.user = user
        self.password = password
        self.urn: str | None = None

    def __enter__(self):
        self.login()
        return self

    def __exit__(self, *exc):
        self.logout()

    def request(self, method: str, path: str, form: dict | list | None = None, session: bool = True):
        body = urllib.parse.urlencode(form).encode() if form is not None else None
        headers = {"Connection": "close"}
        if body is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        if session and self.urn:
            headers["Cookie"] = f"urn={self.urn}"
        conn = http.client.HTTPConnection(self.host, timeout=TIMEOUT)
        try:
            conn.request(method, "/" + path, body=body, headers=headers)
            r = conn.getresponse()
            return r.status, r.getheader("Location"), r.read().decode("utf-8", errors="replace")
        except OSError as e:
            raise RouterError(f"{method} http://{self.host}/{path}: {e}") from None
        finally:
            conn.close()

    def get(self, path: str) -> str:
        status, location, body = self.request("GET", path)
        if status != 200:
            raise RouterError(f"GET /{path}: HTTP {status} (-> {location}); session lost?")
        return body

    def login(self) -> None:
        status, location, _ = self.request(
            "POST",
            "login.cgi",
            {"GO": "status.htm", "pws": hashlib.md5(self.password.encode()).hexdigest(), "usr": self.user},
            session=False,
        )
        if status != 302 or location != "status.htm":
            raise RouterError(f"login refused (HTTP {status} -> {location}); the UI locks after repeated failures")
        # The landing page hands out the session cookie.
        _, _, body = self.request("GET", "status.htm", session=False)
        m = URN.search(body)
        if not m:
            raise RouterError("login: no session cookie (urn) on status.htm")
        self.urn = m.group(1)
        if not self.logged_in():
            raise RouterError("login: the router does not report the session as logged in")

    def logged_in(self) -> bool:
        _, _, body = self.request("GET", "")
        m = LOGGED_IN.search(body)
        return bool(m) and int(m.group(1)) > 0

    def logout(self) -> None:
        if self.urn is None:
            return
        try:
            self.request("POST", "logout.cgi", {})
        finally:
            self.urn = None

    def read_lan(self) -> LanState:
        page = self.get(LAN_PAGE)
        m = PI.search(page)
        if not m:
            raise RouterError(f"{LAN_PAGE}: no pi token (not logged in?)")
        cgi = self.get(LAN_CGI)
        cfg = {name: Cfg(int(i), unescape(v)) for name, i, v in ADD_CFG.findall(cgi)}
        cfg.update({name: Cfg(int(i), unescape(v)) for name, i, v in ADD_CFG.findall(self.get(DMZ_CGI))})
        for need in ("lan_ip1", "lan_mask1", "dhcp_enable1", "dhcp_startip1", "dhcp_endip1", "leasetime1"):
            if need not in cfg:
                raise RouterError(f"{LAN_CGI}: {need} missing")
        reservations = []
        for slot in range(1, MAX_RESERVATIONS + 1):
            name = f"lan_dhcp_reserved_client_1{slot}"
            if name not in cfg:
                raise RouterError(f"{LAN_CGI}: {name} missing")
            r = parse_reservation(slot, cfg[name].value)
            if r:
                reservations.append(r)
        vlan1 = cgi.split("'vlan1'", 1)[1].split("'vlan2'", 1)[0] if "'vlan1'" in cgi else ""
        leases = [
            Lease(unescape(ip), unescape(mac).upper(), unescape(h), unescape(uni), lt)
            for ip, mac, h, uni, lt, _ in LEASE.findall(vlan1)
        ]
        return LanState(m.group(1), cfg, reservations, leases)

    def apply(self, state: LanState, changes: dict[str, str]) -> None:
        """Post changed settings (name -> unescaped value) the way the LAN page does."""
        form = [("CMD", ""), ("GO", LAN_PAGE)]
        for i, (name, value) in enumerate(changes.items()):
            form.append((f"SET{i}", f"{state.cfg[name].id}={escape(value)}"))
        form.append(("pi", state.pi))
        status, location, body = self.request("POST", "apply.cgi", form)
        if status != 200 or not body.startswith("<!DOCTYPE"):
            raise RouterError(f"apply.cgi: HTTP {status} (-> {location}), {body[:80]!r}")
        time.sleep(APPLY_SETTLE)
