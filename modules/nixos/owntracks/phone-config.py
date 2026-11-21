"""OwnTracks remote configuration for Dave's phone (the generator owntracks-phone).

Usage: phone-config.py <out dir> <key file> <url> <user> <device id> <tracker id>

Writes into <out dir>:
  password    the phone's basic-auth password at the front (random)
  htpasswd    edi's nginx auth_basic file for <user> (SHA-512 crypt)
  config.otrc the OwnTracks configuration (JSON, _type configuration)
  page.html   the page Dave opens on the phone: one owntracks:///config
              link holding config.otrc inline, and the file as a fallback

The configuration is tuned for battery: HTTP mode (one request per fix, no
connection kept open), monitoring `significant` (a fix only after moving
`locatorDisplacement` metres and at most every `locatorInterval` seconds;
the F-Droid build then asks Android's fused/network/passive providers,
never GPS alone), a ping (the last known fix again, no new one) every
`ping` minutes, remote commands and remote configuration off, no reverse
geocoding.
"""

import base64
import html
import json
import os
import secrets
import sys
import urllib.parse


def sha512_crypt(password: str) -> str:
    import subprocess

    return subprocess.run(
        ["openssl", "passwd", "-6", "-stdin"],
        input=password.encode(),
        capture_output=True,
        check=True,
    ).stdout.decode().strip()


def config(url, user, password, key, device, tid):
    return {
        "_type": "configuration",
        "mode": 3,  # HTTP
        "url": url,
        "username": user,
        "password": password,
        "deviceId": device,
        "tid": tid,
        "encryptionKey": key,
        "monitoring": 1,  # significant changes
        "locatorDisplacement": 500,  # metres
        "locatorInterval": 600,  # seconds
        "ping": 60,  # minutes between keep-alive reports (last known fix)
        "autostartOnBoot": True,
        "extendedData": True,  # battery level (and Wi-Fi name) with each fix
        "cmd": False,
        "remoteConfiguration": False,
        "publishLocationOnConnect": False,
        "reverseGeocodeProvider": "None",
    }


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>OwnTracks setup</title>
<style>
body {{ font-family: sans-serif; margin: 2em auto; max-width: 32em; padding: 0 1em; line-height: 1.5 }}
a.button {{ display: block; text-align: center; padding: 1em; margin: 1.5em 0;
  background: #2b6cb0; color: #fff; border-radius: .5em; text-decoration: none; font-size: 1.2em }}
code {{ word-break: break-all }}
</style></head><body>
<h1>OwnTracks for your phone</h1>
<p>With OwnTracks installed (F-Droid, <code>org.owntracks.android</code>),
tap the button on the phone, then <b>Import</b> in OwnTracks.</p>
<a class="button" href="{link}">Configure OwnTracks</a>
<p>If the button does nothing: <a href="{otrc}" download>download the
configuration file</a> and open it with OwnTracks.</p>
<p>Afterwards in OwnTracks: allow location <b>all the time</b>, and set
OwnTracks to <b>Unrestricted</b> battery use only if reports stop while the
phone sleeps. The configuration reports to <code>{url}</code> as
<code>{user}</code>/<code>{device}</code>, encrypted, on significant moves
(about 500 m) and every {ping} minutes.</p>
<p>This page holds the phone's password and encryption key: don't share it.</p>
</body></html>
"""


def main(out, key_file, url, user, device, tid):
    with open(key_file) as f:
        key = f.read().strip()
    password = secrets.token_hex(24)
    cfg = config(url, user, password, key, device, tid)
    blob = json.dumps(cfg, indent=2) + "\n"
    inline = base64.b64encode(json.dumps(cfg, separators=(",", ":")).encode()).decode()
    # OwnTracks URL-decodes the query value ('+' would become a space)
    link = "owntracks:///config?inline=" + urllib.parse.quote(inline, safe="")
    files = {
        "password": password,
        "htpasswd": f"{user}:{sha512_crypt(password)}\n",
        "config.otrc": blob,
        "page.html": PAGE.format(
            link=html.escape(link, quote=True),
            otrc="config.otrc",
            url=html.escape(url),
            user=html.escape(user),
            device=html.escape(device),
            ping=cfg["ping"],
        ),
    }
    for name, content in files.items():
        with open(os.path.join(out, name), "w") as f:
            f.write(content)


if __name__ == "__main__":
    main(*sys.argv[1:7])
