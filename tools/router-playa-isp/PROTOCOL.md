# Orange Livebox Fibra (Arcadyan PRV3399B) — web UI protocol

Recorded on 2026-11-08 against the live router at `192.168.10.1` (playa's
LAN gateway and DHCP server), reached from amy over zt-eu. Everything below
was read from the device or its JavaScript; only the DHCP reservation write
was exercised (see the end).

## Device

From `cgi/cgi_info.js` (support_information.htm), logged in:

```
product_name  PRV3399B_B_LT          HW / board_ver  ARLTLBFIB2.0.0
fw_ver        v0.03.05.229B-ES       bootCode        1.2.4-ES
service       OSP                    cvlan           832
```

Orange Spain's "Livebox Fibra" (GPON ONT + router, `ploam_state` in the
config), Arcadyan firmware (`arc-*.js`, `OSP_ARC245` markers). `Server:
httpd`, plain HTTP on port 80 (`force_https` = 0). UI in English/Spanish
(`lang/en.js`, `lang/sp.js`). LAN `192.168.10.1/24`; a second, internal
interface `lan_ip3` = `192.168.144.1`.

## Page/script model

Pages are `*.htm` with a `scripts = {cgi: [...], other: [...]}` header;
`js/loadScripts.js` loads `js/<other>` and `cgi/cgi_<name>.js`. The cgi
scripts are generated per request and carry the settings as

```
addCfg("<name>", <id>, '<value>');
```

`<value>` is escaped with `arc.str.escape` (every char outside
`[0-9A-Za-z]` as `%XX`, upper-case hex); the UI reads it back with JS
`unescape()` applied twice. `<id>` is the number a change is posted under;
it is **randomised per login session** (the same within one session, e.g.
`lan_ip1` was 87105039 in one session and 26040636 in the next, and differs
between cgi scripts), so ids are always taken from a fresh read in the
session that writes. Unknown paths answer with the login frameset (200);
protected paths without a session answer `302` to `index.htm`.

## Login, session, logout

`firstlogin.htm` (user is fixed to `admin`):

```
POST /login.cgi   (application/x-www-form-urlencoded)
  GO=status.htm&pws=<md5_hex(password)>&usr=admin
-> 302 Location: status.htm, no Set-Cookie
GET /status.htm
-> 200, script: var new_urn = '<16 hex>'; top.setCookie("urn", new_urn)
```

The session is the cookie `urn=<16 hex>` from that page; every later
request sends `Cookie: urn=...`. `GET /` shows the state:
`bUsrisLogined = parseInt('0'+'1')` logged in, `'-1'` not (without the
cookie it always says `-1`). `cgi/cgi_authpage.js` (no login needed) has
`http_lock` (1 = login locked after repeated failures; the UI shows a lock
popup and polls until it clears) and `last_local_login`. The form also
carries the plain password in `ui_pws` from a browser; the server does not
need it.

Logout: `POST /logout.cgi` (empty body, with the cookie) -> 302 `index.htm`;
afterwards the cookie gets `302` again.

## LAN / DHCP read

Page `advanced_network_configuration.htm` (Advanced > Network > DHCP),
`scripts.cgi = ["lan", "status", "fw_dmz"]`. Its
`<meta name="pi" content="<16 chars>">` is the form token posted with
changes. `cgi/cgi_lan.js`:

| name                                  | meaning                               | value (2026-11-08)  |
|---------------------------------------|---------------------------------------|---------------------|
| `lan_ip1`, `lan_mask1`                | LAN address                           | 192.168.10.1/255.255.255.0 |
| `dhcp_enable1`                        | DHCPv4 server on                      | 1                   |
| `dhcp_startip1`, `dhcp_endip1`        | pool                                  | .100 – .250         |
| `leasetime1`                          | lease time, seconds (no UI field)     | 86400               |
| `domain_name1`                        |                                       | home                |
| `lan_dhcp_reserved_client_1<n>`       | reservation slot n = 1..32: `ip,MAC,label` or empty | |
| `lan_ip6eb1`                          | DHCPv6/IPv6 on LAN                    | 1                   |
| `*2`, `lan_dhcp_reserved_client_2<n>` | second VLAN, unused                   |                     |
| `dhcp_option*`                        | DHCP classes (9), unused              |                     |

plus `dhcpList.vlan1` (current leases: `{ip, mac, hostname, uni (eth1.0 /
wl0.x), leaseTime, createdTime}`). `cgi/cgi_fw_dmz.js` has `dmz_enable`,
`client_ip`, `client_mac` (DMZ off).

Reservations found: slot 1 `192.168.10.2,94:83:C4:A4:38:09,GL-MT6000`,
slot 2 `192.168.10.21,B8:27:EB:8C:E2:B5,tossa-pi`, slot 3
`192.168.10.3,D8:3A:DD:ED:E0:A9,homeassistant`. All three are outside the
pool; the page then shows "At least one static IP address is out of DHCP
range defined" (a warning only, nothing is refused).

## Writes

`js/global.js` `subForm()` builds a hidden form for every changed
("dirty") setting and posts it:

```
POST /apply.cgi
  CMD=&GO=advanced_network_configuration.htm
  &SET0=<id>=<escaped value>&SET1=...      (one per changed setting)
  &pi=<pi of the page>
-> 200, an HTML page starting with <!DOCTYPE
```

(form-encoded on top, so `SET0=4711%3D192%252E168...`). The page's checks
are client side only:

- Add a reservation (`manual_reserve_save`): the first empty slot gets
  `ip,MAC,label`; picking a connected device posts its upper-case MAC and
  its hostname as label, a manual entry the lower-case MAC and an empty
  label. Refused in the page: IP equal to the router's, IP or MAC already
  in another slot. Waits 3 s.
- Delete (`manual_reserve_delete`): the slot set to empty; if its IP is the
  DMZ host, `dmz_enable`/`client_ip`/`client_mac` are cleared in the same
  post.
- Pool: `lan_ip1`, `dhcp_startip1`, `dhcp_endip1` are posted only after a
  confirmation: "You may lose the router management temporarily ... any
  related configuration (NAT, PCP rules, DMZ or DHCP reservation) are going
  to be deleted" (Spanish: "El router se reiniciará"). `dhcp_enable1`,
  `lan_ip6eb1` and `lan_mask1` go in a post of their own. Lease time has no
  field.

Exercised on 2026-11-08: adding slot 4
(`192.168.10.182,2C:1B:3A:75:04:A6,e1-camera`) with `router-playa-isp`:
`apply.cgi` answered 200 `<!DOCTYPE...`, a re-read of `cgi_lan.js` in the
same session showed the slot, the next run (new session, new ids) found
nothing to change. No restart (`uptime` in `cgi_info.js` kept counting) and
the device's current lease (`.181`) was left alone: a reservation applies
at the client's next DHCP request. Not exercised: pool, lease time,
enable/mask writes, deleting a reservation.
