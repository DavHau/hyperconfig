# ZTE F6107A (AIS firmware `F6107A_PON_2.0`, hardware V9.0.05) web protocol

Reverse-engineered on 2026-09-06 against the live device at `http://192.168.1.1`
by driving the UI in Chromium and reading the page JavaScript (`/`,
`/jquery/common_lib.js`). Everything below was verified on the wire.

All endpoints live under `/` and are selected by query string:
`/?_type=<kind>&_tag=<name>`. Kinds: `loginData`, `hiddenData`, `menuView`
(HTML fragments with page JS), `menuData` (XML data behind a page).

## Session

* First `GET /` sets the `SID` cookie (and `_TESTCOOKIESUPPORT=1`). `SID` is
  re-issued on several responses; a cookie jar is required.
* The logged-in `/` page and every `menuView` fragment embed
  `_sessionTmpToken = "\x41\x62..."` (hex-escaped, 24 chars). This token is
  appended to every data POST as `_sessionTOKEN`. **Loading a `menuView`
  rotates it**; a POST with a stale token answers
  `IF_ERRORID -1452 "This page has expired, please refresh and try again."`.
* Logged-out `/` has `var _sessionTmpToken = "";` — that is how the client
  tells the two states apart.
* Logout: `POST /?_type=loginData&_tag=logout_entry` body `IF_LogOff=1`.

## Login

```
GET  /?_type=hiddenData&_tag=captcha_data          # generates a new captcha (empty body)
GET  /?_type=loginData&_tag=login_entry            # {"lockingTime":0,"loginErrMsg":"","promptMsg":"","sess_token":"<24 chars>"}
GET  /webimg/captcha.jpg?<random>                  # 70x20 JPEG
GET  /?_type=loginData&_tag=login_token            # <ajax_response_xml_root>NNNNNNNN</ajax_response_xml_root>
POST /?_type=loginData&_tag=login_entry
     action=login&Password=<sha256hex(password + login_token)>&Username=admin
     &_sessionTOKEN=<sess_token>&captcha=<6 chars>
```

Order matters: `captcha_data` must be fetched before `login_entry`, and
`login_token` immediately before the POST (each GET rotates it).

Responses of the POST:

* success: `{"sess_token":"...","login_need_refresh":true}` — then `GET /`
  returns the logged-in page (or the preempt page, see below).
* wrong captcha: `{"lockingTime":-1,"loginErrMsg":"Validate code is not correct. ",...}`
* wrong password: `{"lockingTime":-1,"loginErrMsg":"Username or password is error. ",...}`
* third consecutive failure (captcha failures count too):
  `{"lockingTime":60,"promptMsg":"You have login failed for {0} times continuously. "}`.
  During the lock `login_entry` GET also reports `lockingTime > 0`.
  The client waits it out once when it is at most 90 s.

### Captcha

`ValidateCode` is on in `commConf`. The image is six characters of an 8x14
pixel font, blue (#0080D0-ish) on near-white, at x = 5 + 9·i, y = 4, with no
rotation, noise or distortion. The alphabet is `A-Z a-z 2-9` minus `I O l`
(57 characters; never observed `0 1 I O l` in 100+ samples). Every glyph
occurrence is pixel-identical, so `captcha.py` thresholds blue−red > 60 and
matches each cell against `glyphs.py` by Hamming distance (≤ 2). Tesseract
(`--psm 7`, whitelist) is only a fallback if a cell matches nothing; on its
own it read about 50% of samples correctly.

## Session conflict ("Another user is configuring the device")

The router keeps one admin web session.

* A login from the **same client IP** as the existing session silently
  replaces it: the old session's requests start returning
  `<IF_ERRORSTR>SessionTimeout</IF_ERRORSTR>` and the old browser bounces to
  the sign-in page. No dialog. (Note this LAN sits behind a second router, so
  every host here appears to the ZTE as `192.168.1.104`.)
* A login from a **different IP** succeeds (`login_need_refresh`), but the
  next `GET /` is the preempt page:

  ```html
  <span id="login_warn_span">Warning! Another user is configuring the device! ...</span>
  <input type="radio" name="preempt_sessid" value=<64 hex> checked/>
  <label for="radio1">192.168.1.104(admin)</label>   <!-- HTML-entity encoded -->
  ```

  Force: `POST /?_type=loginData&_tag=login_preempt` with
  `preempt_sessid=<hex>&action=preempt` → `{"login_need_refresh":true}`, and
  `GET /` is now the logged-in page. Decline: same endpoint with
  `action=preempt_cancel`. Either way the older session is already dead by
  then. `router-ais --no-force` takes the cancel branch and exits 1.

Reaching the router on its IPv6 address (`2405:9800:b901:94e3:ea81:75ff:fec9:619c`)
works only with `Host: 192.168.1.1`; an IPv6-literal Host header gets HTTP 400.
That is how the preempt path was exercised from this host.

## Data POSTs (`menuData`)

Body is `application/x-www-form-urlencoded`, built exactly like the page JS
`InitialPostData`: `IF_ACTION=<Apply|Delete>` followed by every form field of
the template in DOM order, each value `encodeURIComponent`-encoded, then
`&_sessionTOKEN=<token>`.

The UI (`commConf.IntegCheck`) adds a `Check` header:
`base64(RSA_PKCS1v15_encrypt(pubkey, sha256hex(body)))` with the 2048-bit
public key embedded in `/` (`asyEncode`). **The router enforces it**: a POST
without `Check` is answered HTTP 400. The client extracts the PEM from the
page and encrypts with `cryptography`.

Responses are XML: `<IF_ERRORID>0</IF_ERRORID>` on success plus, for Apply of
a new instance, `<INSTIDENTITY>` and `<_InstID>` with the new object id.

`menuData` GETs only return content **after the page's `menuView` was loaded
in the same session**; before that they answer an empty success envelope.
The client therefore loads `/?_type=menuView&_tag=filterCriteria&Menu3Location=0`
before reading or writing IP filter data.

## Device info

`GET /?_type=menuData&_tag=home_ais_lua.lua` → `OBJ_DEVINFO_ID` instance with
`SoftwareVer`, `ModelName`, `HardwareVer`, `SerialNumber` (and more objects).

## IPv6 inbound allow = "IP Filter" rules

Menu: Internet → Security → Filter Criteria → "IP Filter" section.
Page view tag `filterCriteria`, data tag `firewall_ipfilter_lua.lua`, object
`OBJ_FWIP_ID`, instances `DEV.FW.CHAIN1.IPF<n>`.

Instance parameters (as returned by the GET):

| ParaName | meaning |
|---|---|
| `_InstID` / `ViewName` | `DEV.FW.CHAIN1.IPFn` |
| `Name` | 1–32 chars |
| `Enable` | `1`/`0` |
| `FilterTarget` | `1` allow, `0` discard |
| `FilterIndex` | order 1–20 (UI dropdown) |
| `IPVersion` | `-1` any, `4`, `6` |
| `SourceIP`, `SourceIPMask` | address and `addr/prefix`; empty = any |
| `DestIP`, `DestIPMask` | idem |
| `Protocol` | `256` any, `6` tcp, `17` udp, `257` tcp+udp, `58` icmpv6, `1` icmp, or a raw number |
| `MinSrcPort`,`MaxSrcPort`,`MinDstPort`,`MaxDstPort` | `-1` = any |
| `INCViewName`, `OUTCViewName` | ingress/egress interface; empty = any; `DEV.IP.IF1` LAN, `DEV.IP.IF3` `aisfibre_ipv6_ipv4_pppoe`, `DEV.IP.IF4` `AIS Internet` |
| `DSCP` | `-1` = any |

The reference rule created by hand for the inference VM:

```
_InstID=DEV.FW.CHAIN1.IPF1 Name=inference Enable=1 FilterTarget=1 FilterIndex=1
IPVersion=6 DestIP=2405:9800:b901:94e3::feed:da7a DestIPMask=2405:9800:b901:94e3::feed:da7a/128
Protocol=256 ports=-1 INCViewName= OUTCViewName= DSCP=-1
```

Add (exact body captured from the UI, `%xx` decoded here):

```
IF_ACTION=Apply&Enable=1&_InstID=-1&Name=<name>&FilterTarget=1&FilterIndex=<n>
&IPVersion=6&SourceIPMask=&DestIPMask=<addr>/128&SourceIP=&SMask=&DestIP=<addr>&DMask=128
&Protocol=6&hiddenProtocol=6&MinSrcPort=-1&MaxSrcPort=-1&MinDstPort=22&MaxDstPort=22
&INCViewName=&OUTCViewName=&DSCP=-1&Btn_cancel_IPFilter=&Btn_apply_IPFilter=&_sessionTOKEN=<token>
```
→ `<INSTIDENTITY>DEV.FW.CHAIN1.IPF2</INSTIDENTITY>...<_InstID>DEV.FW.CHAIN1.IPF2</_InstID>`

Delete: same field set with `IF_ACTION=Delete&_InstID=DEV.FW.CHAIN1.IPF2`
(the UI resends the whole form). Response `IF_ERRORID 0`, and the instance
is gone from the next GET.

Observed quirks:

* `FilterIndex` is a position: inserting with `FilterIndex=1` pushes the
  existing rules down (the reference rule showed `FilterIndex=2` until the
  test rule was deleted). The client always appends (`len(rules)+1`).
* No reboot or "apply" step is needed; rules are live immediately.
* The UI offers order values 1–20, which is presumably the rule limit.
* Instance ids are reused: after deleting `IPF2` the next add is `IPF2` again.
* The old `SID` from a previous, silently replaced session is dead; the
  router does not tell the *new* session anything about it.
