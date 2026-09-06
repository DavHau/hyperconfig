# router-ais

CLI for the AIS-issued ZTE F6107A home router (`http://192.168.1.1`): log in
through its captcha and manage the IPv6 inbound-allow rules ("IP Filter" under
Internet → Security → Filter Criteria). Built as `packages.router-ais` from
`modules/flake-parts/router-ais.nix` and included in the default devshell.

```
router-ais [--host 192.168.1.1] [--json] [--no-force] [-v] login
router-ais ipv6-rules list
router-ais ipv6-rules add --address <ipv6> [--proto any|tcp|udp|both|icmpv6] [--port N|N-M] [--name NAME]
router-ais ipv6-rules delete <#|IPFn|name> [--i-know]
```

Examples:

```
$ router-ais login
session ok: F6107A firmware F6107A_PON_2.0 hardware V9.0.05 serial ZTEEQM0N7C21014

$ router-ais ipv6-rules list
#  inst  name       on   target  ipv  proto  src  dst                                 sport  dport  in   out  order
1  IPF1  inference  yes  allow   6    any    any  2405:9800:b901:94e3::feed:da7a/128  any    any    any  any  1

$ router-ais ipv6-rules add --address 2405:9800:b901:94e3::feed:50ab --proto tcp --port 22 --name som
added DEV.FW.CHAIN1.IPF2 som: tcp -> 2405:9800:b901:94e3::feed:50ab/128 port 22

$ router-ais ipv6-rules delete som
deleted DEV.FW.CHAIN1.IPF2 som
```

`add` creates an enabled *allow* rule for `<address>/128` as destination, any
source, any interface, appended after the existing rules. Without `--proto`
the rule matches every protocol (like the hand-made `inference` rule);
`--port` requires `--proto tcp|udp|both`. The default name is `v6-<last 4 hex>`.

`delete` accepts the row number from `list`, the short instance id (`IPF2`)
or the name. It refuses to delete the rule for
`2405:9800:b901:94e3::feed:da7a` (the inference VM's live demo) unless
`--i-know` is given.

`--json` prints machine-readable output; `-v` logs the login flow (captcha
attempts, session preemption) to stderr. Exit status is non-zero on any
failure.

## Credentials

User is `admin`. The password comes from `ROUTER_AIS_PASSWORD` if set,
otherwise from `clan vars get amy router-ais/password` (run inside the
hyperconfig checkout; about 3 s). It is never written anywhere.

## Sessions and the captcha

Every invocation logs in, does its work and logs out again. The router holds
a single admin web session, so running the tool kicks out whoever is logged
in through a browser (and vice versa). When the router presents its
"Another user is configuring the device" page the tool forces that session
out; `--no-force` declines instead and exits 1. See `PROTOCOL.md` for when the
router shows that page and when it just replaces the session silently.

The login captcha is read by matching its fixed pixel font
(`router_ais/glyphs.py`); tesseract is only a fallback. Three failed logins
in a row (bad captcha counts) lock the router for 60 s; the tool waits that
out once and retries, up to 8 attempts in total.

## Limitations

* Only the IP Filter rule set is covered; WAN, wifi, DHCP, port forwarding
  etc. are deliberately out of scope.
* `add` always writes IPv6, destination-only, allow rules. Editing existing
  rules is not supported: delete and re-add.
* The UI allows 20 rules; the tool does not check that limit itself.
* Reaching the router by its IPv6 address needs a `Host: 192.168.1.1` header,
  which the CLI does not set; use the IPv4 address.
