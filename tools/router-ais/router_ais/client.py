"""HTTP client for the ZTE F6107A web UI. See PROTOCOL.md for the wire details."""

import base64
import hashlib
import json
import re
import time
import urllib.parse
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from html import unescape

import requests
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import padding

from . import captcha

CAPTCHA_ATTEMPTS = 8
MAX_LOCK_WAIT = 90  # seconds; the router locks for 60s after three failed logins
IPFILTER_TAG = "firewall_ipfilter_lua.lua"
IPFILTER_VIEW = "filterCriteria"
DEVINFO_TAG = "home_ais_lua.lua"
PREEMPT_MARKER = 'name="preempt_sessid"'

# Protocol numbers as the router models them.
PROTO_ANY = "256"
PROTO_TCP = "6"
PROTO_UDP = "17"
PROTO_ICMPV6 = "58"
PROTO_TCPUDP = "257"
PROTO_NAMES = {PROTO_ANY: "any", PROTO_TCP: "tcp", PROTO_UDP: "udp", PROTO_ICMPV6: "icmpv6", PROTO_TCPUDP: "both"}
PROTO_BY_NAME = {v: k for k, v in PROTO_NAMES.items()}


class RouterError(Exception):
    pass


class SessionConflict(RouterError):
    """Another web session holds the router's single admin session."""


class CaptchaFailed(RouterError):
    pass


@dataclass
class Rule:
    inst_id: str
    name: str
    enabled: bool
    target: str  # allow | discard
    ip_version: str  # any | 4 | 6
    protocol: str  # any | tcp | udp | both | icmpv6 | <number>
    src: str
    dst: str
    src_ports: str
    dst_ports: str
    ingress: str
    egress: str
    dscp: str
    order: str
    raw: dict

    @property
    def address(self) -> str:
        return self.raw.get("DestIP", "")


def _ports(lo: str, hi: str) -> str:
    if lo in ("", "-1"):
        return "any"
    return lo if lo == hi else f"{lo}-{hi}"


def _quote(value) -> str:
    # Mirror JS encodeURIComponent so the body hashed for the Check header is what the UI would send.
    return urllib.parse.quote(str(value), safe="-_.!~*'()")


def parse_instances(xml_text: str, obj_tag: str) -> list[dict]:
    root = ET.fromstring(xml_text)
    _raise_on_error(root)
    out = []
    obj = root.find(obj_tag)
    if obj is None:
        return out
    for inst in obj.findall("Instance"):
        names = [e.text or "" for e in inst.findall("ParaName")]
        values = [e.text or "" for e in inst.findall("ParaValue")]
        out.append(dict(zip(names, values)))
    return out


def _raise_on_error(root: ET.Element) -> None:
    err_id = root.findtext("IF_ERRORID")
    if err_id not in (None, "0"):
        msg = root.findtext("IF_ERRORSTR") or "unknown error"
        raise RouterError(f"router error {err_id}: {msg.strip()}")


class Router:
    def __init__(self, host: str, password: str, *, force: bool = True, log=lambda msg: None):
        self.base = f"http://{host}"
        self.password = password
        self.force = force
        self.log = log
        self.session = requests.Session()
        self.token = ""  # _sessionTmpToken, rotated by every menuView load
        self._pubkey = None
        self._view = None

    # -- transport -----------------------------------------------------------------

    def _get(self, path: str, **kw) -> requests.Response:
        r = self.session.get(self.base + path, timeout=20, **kw)
        r.raise_for_status()
        return r

    def _post(self, path: str, data, headers=None) -> requests.Response:
        r = self.session.post(self.base + path, data=data, headers=headers, timeout=30)
        r.raise_for_status()
        return r

    # -- login ---------------------------------------------------------------------

    def login(self) -> None:
        html = self._get("/").text
        self._absorb_page(html)
        if self.token:
            self.log("already logged in (cookie session)")
            return
        for attempt in range(1, CAPTCHA_ATTEMPTS + 1):
            result = self._login_once()
            if result is None:
                self.log(f"login ok after {attempt} captcha attempt(s)")
                return
            self.log(f"login attempt {attempt}/{CAPTCHA_ATTEMPTS} rejected: {result}")
        raise CaptchaFailed(f"login failed after {CAPTCHA_ATTEMPTS} attempts")

    def _login_once(self):
        """One captcha+login round. Returns None on success, else a reason to retry."""
        self._get("/?_type=hiddenData&_tag=captcha_data")
        entry = self._get("/?_type=loginData&_tag=login_entry").json()
        if self._wait_lock(entry):
            return "waited out login lock"
        code, method = captcha.solve(self._get("/webimg/captcha.jpg", params={"_": time.time()}).content)
        if len(code) != 6:
            return f"captcha {method} produced {code!r}"
        salt = self._get("/?_type=loginData&_tag=login_token").text
        salt = re.search(r"<ajax_response_xml_root>(.*?)</ajax_response_xml_root>", salt).group(1)
        result = self._post(
            "/?_type=loginData&_tag=login_entry",
            {
                "action": "login",
                "Password": hashlib.sha256((self.password + salt).encode()).hexdigest(),
                "Username": "admin",
                "_sessionTOKEN": entry["sess_token"],
                "captcha": code,
            },
        ).json()
        if result.get("login_need_refresh"):
            html = self._get("/").text
            if PREEMPT_MARKER in html:
                html = self._preempt(html)
            self._absorb_page(html)
            if self.token:
                return None
            raise RouterError("login reported success but no session token on page")
        if self._wait_lock(result):
            return "waited out login lock"
        msg = result.get("loginErrMsg", "")
        if "Validate code" in msg:
            return f"wrong captcha ({method} read {code!r})"
        if "password" in msg.lower():
            raise RouterError("router rejected the password")
        if msg:
            raise RouterError(f"login failed: {msg.strip()}")
        return f"unexpected login response {json.dumps(result)}"

    def _preempt(self, html: str) -> str:
        """Handle the 'Another user is configuring the device' page after login."""
        sessions = re.findall(r'name="preempt_sessid" value=([0-9a-f]+)', html)
        labels = [unescape(s) for s in re.findall(r'<label for="radio\d+">(.*?)</label>', html)]
        who = ", ".join(labels) or "unknown"
        if not self.force:
            self._post("/?_type=loginData&_tag=login_preempt", {"action": "preempt_cancel"})
            raise SessionConflict(f"another session is active ({who}); rerun without --no-force to log it out")
        for sid in sessions:
            self.log(f"forcing logout of other session ({who})")
            self._post("/?_type=loginData&_tag=login_preempt", {"preempt_sessid": sid, "action": "preempt"})
        html = self._get("/").text
        if PREEMPT_MARKER in html:
            raise SessionConflict(f"could not preempt the other session ({who})")
        return html

    def _wait_lock(self, j: dict) -> bool:
        """Three failed logins lock the router for 60s. Wait it out once when short."""
        lock = int(j.get("lockingTime", 0) or 0)
        if lock <= 0:
            return False
        if lock > MAX_LOCK_WAIT:
            raise RouterError(f"router login is locked for {lock}s: {j.get('promptMsg', '').strip()}")
        self.log(f"router login locked for {lock}s, waiting")
        time.sleep(lock + 1)
        return True

    def _absorb_page(self, html: str) -> None:
        m = re.search(r'_sessionTmpToken\s*=\s*"([^"]*)"', html)
        if m:
            self.token = m.group(1).encode().decode("unicode_escape")
        if self._pubkey is None:
            k = re.search(r'"(-----BEGIN PUBLIC KEY-----\\n.*?-----END PUBLIC KEY-----)"', html)
            if k:
                pem = k.group(1).replace("\\n", "\n").encode()
                self._pubkey = serialization.load_pem_public_key(pem)

    def logout(self) -> None:
        try:
            self._post("/?_type=loginData&_tag=logout_entry", {"IF_LogOff": 1})
        finally:
            self.token = ""

    # -- data access ---------------------------------------------------------------

    def load_view(self, tag: str) -> None:
        """Load a menu page. This is what makes the page's menuData endpoints answer
        with content, and it rotates _sessionTmpToken, which every POST must carry."""
        html = self._get(f"/?_type=menuView&_tag={tag}&Menu3Location=0", params={"_": time.time()}).text
        self._absorb_page(html)
        if not self.token:
            raise RouterError("not logged in (menu page carried no session token)")
        self._view = tag

    def get_data(self, tag: str) -> str:
        return self._get(f"/?_type=menuData&_tag={tag}", params={"_": time.time()}).text

    def post_data(self, tag: str, fields: list[tuple[str, str]]) -> ET.Element:
        body = "&".join(f"{k}={_quote(v)}" for k, v in fields)
        body += f"&_sessionTOKEN={self.token}"
        digest = hashlib.sha256(body.encode()).hexdigest()
        check = base64.b64encode(self._pubkey.encrypt(digest.encode(), padding.PKCS1v15())).decode()
        r = self._post(
            f"/?_type=menuData&_tag={tag}",
            body.encode(),
            headers={"Content-Type": "application/x-www-form-urlencoded", "Check": check},
        )
        root = ET.fromstring(r.text)
        _raise_on_error(root)
        return root

    def device_info(self) -> dict:
        inst = parse_instances(self.get_data(DEVINFO_TAG), "OBJ_DEVINFO_ID")
        return inst[0] if inst else {}

    # -- IP filter rules -----------------------------------------------------------

    def _ensure_view(self, tag: str) -> None:
        if self._view != tag:
            self.load_view(tag)

    def ip_rules(self) -> list[Rule]:
        self._ensure_view(IPFILTER_VIEW)
        rules = []
        for p in parse_instances(self.get_data(IPFILTER_TAG), "OBJ_FWIP_ID"):
            rules.append(
                Rule(
                    inst_id=p["_InstID"],
                    name=p.get("Name", ""),
                    enabled=p.get("Enable") == "1",
                    target="allow" if p.get("FilterTarget") == "1" else "discard",
                    ip_version={"-1": "any"}.get(p.get("IPVersion", "-1"), p.get("IPVersion", "")),
                    protocol=PROTO_NAMES.get(p.get("Protocol", ""), p.get("Protocol", "")),
                    src=p.get("SourceIPMask") or "any",
                    dst=p.get("DestIPMask") or "any",
                    src_ports=_ports(p.get("MinSrcPort", "-1"), p.get("MaxSrcPort", "-1")),
                    dst_ports=_ports(p.get("MinDstPort", "-1"), p.get("MaxDstPort", "-1")),
                    ingress=p.get("INCViewName") or "any",
                    egress=p.get("OUTCViewName") or "any",
                    dscp=p.get("DSCP", "-1"),
                    order=p.get("FilterIndex", ""),
                    raw=p,
                )
            )
        return rules

    def _rule_fields(self, action: str, inst_id: str, p: dict) -> list[tuple[str, str]]:
        # Field order mirrors the UI form (InitialPostData walks the DOM in order).
        return [
            ("IF_ACTION", action),
            ("Enable", p["Enable"]),
            ("_InstID", inst_id),
            ("Name", p["Name"]),
            ("FilterTarget", p["FilterTarget"]),
            ("FilterIndex", p["FilterIndex"]),
            ("IPVersion", p["IPVersion"]),
            ("SourceIPMask", p["SourceIPMask"]),
            ("DestIPMask", p["DestIPMask"]),
            ("SourceIP", p["SourceIP"]),
            ("SMask", p["SourceIPMask"].rsplit("/", 1)[1] if "/" in p["SourceIPMask"] else ""),
            ("DestIP", p["DestIP"]),
            ("DMask", p["DestIPMask"].rsplit("/", 1)[1] if "/" in p["DestIPMask"] else ""),
            ("Protocol", p["Protocol"]),
            ("hiddenProtocol", p["Protocol"] if p["Protocol"] in PROTO_NAMES else "other"),
            ("MinSrcPort", p["MinSrcPort"]),
            ("MaxSrcPort", p["MaxSrcPort"]),
            ("MinDstPort", p["MinDstPort"]),
            ("MaxDstPort", p["MaxDstPort"]),
            ("INCViewName", p["INCViewName"]),
            ("OUTCViewName", p["OUTCViewName"]),
            ("DSCP", p["DSCP"]),
            ("Btn_cancel_IPFilter", ""),
            ("Btn_apply_IPFilter", ""),
        ]

    def add_ipv6_allow(self, address: str, proto: str, ports: tuple[int, int] | None, name: str, order: int) -> str:
        lo, hi = (str(ports[0]), str(ports[1])) if ports else ("-1", "-1")
        params = {
            "Enable": "1",
            "Name": name,
            "FilterTarget": "1",
            "FilterIndex": str(order),
            "IPVersion": "6",
            "SourceIPMask": "",
            "SourceIP": "",
            "DestIPMask": f"{address}/128",
            "DestIP": address,
            "Protocol": PROTO_BY_NAME[proto],
            "MinSrcPort": "-1",
            "MaxSrcPort": "-1",
            "MinDstPort": lo,
            "MaxDstPort": hi,
            "INCViewName": "",
            "OUTCViewName": "",
            "DSCP": "-1",
        }
        self._ensure_view(IPFILTER_VIEW)
        root = self.post_data(IPFILTER_TAG, self._rule_fields("Apply", "-1", params))
        return root.findtext("_InstID") or root.findtext("INSTIDENTITY") or ""

    def delete_rule(self, rule: Rule) -> None:
        self._ensure_view(IPFILTER_VIEW)
        self.post_data(IPFILTER_TAG, self._rule_fields("Delete", rule.inst_id, rule.raw))
