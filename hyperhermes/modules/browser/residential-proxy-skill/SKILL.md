---
name: residential-proxy
description: The host's paid residential proxy (home IP, pick the country). Use only when a site blocked web_extract or the browser (403, bot wall, access denied, region block), or a task needs an exit in another country.
---

# Residential proxy (opt-in, paid)

This host has a residential proxy: requests through it leave from a real
home internet connection in the country you choose, instead of this
host's own datacenter/VPN address. Sites that block datacenter addresses
usually let it through.

It costs real money per gigabyte, shared by every agent on this host,
and it runs out. So:

- **Never the first try.** Use `web_extract` and the `browser_*` tools as
  usual (the `web-access` skill). Reach for the proxy only when a site
  blocked them: HTTP 403, a bot wall that the browser's challenge wait
  did not clear, "access denied", "unusual traffic", or a region block
  ("not available in your country").
- **Never for logins to the owner's accounts** (their email, bank,
  shops, social media) unless the owner asked for it: a login from a
  random home IP abroad can lock the account.
- **Text over pages:** prefer `web_extract_residential` to the browser;
  a browser session through the proxy loads every image and script.
- No downloads of large files, videos or images through it.

## Tools

- `web_extract_residential(urls, country?)`: `web_extract` through the
  proxy (the same extraction, browser retry included). `country` is an
  ISO two-letter code (`SG` default, `US`, `DE`, `JP`, ...).
- `browser_residential(country)`: puts this task's browser onto the
  proxy, then `browser_navigate` as usual. It is a separate browser profile
  per country: none of the usual cookies or logins go along. `browser_residential`
  with `country: "off"` switches back; do that once the blocked page is
  done.
- Terminal: `curl -x "$RESIDENTIAL_PROXY_URL" -U sg: <url>` (the proxy
  username is the country: `sg`, `us`, ...; `us-session-ab12cd34` keeps
  the same exit IP for about 30 minutes; the password is ignored). Only
  for APIs or files, never with a spoofed browser User-Agent.

Pick the country the site expects: the site's own country for regional
services, otherwise the default.

## Errors

- "the paid traffic is probably used up" / HTTP 402 from the proxy: the
  package is empty. Do not retry and do not try other countries. Go on
  without it and tell the user that the residential proxy is out of
  traffic.
- "could not reach the site via <country>": try once more with another
  country, then report the site as blocked.
- Still blocked through the proxy: the site blocks more than the IP
  (fingerprint, account). Report it; do not loop.

`web_search` needs nothing from you: SearXNG's engines that this host's
own exit cannot reach go through the proxy on their own.
