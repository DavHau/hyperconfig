"""Sample-sentence translator for the voice picker (voices.html).

POST /translate {"text": "..."} -> {"source": "en"|"de"|"th", "en": "...", "de": "...", "th": "..."}

Detects the language of the text and translates it into the other two with
p0's Qwen (OpenAI-compatible, thinking off). Listens on 127.0.0.1 only;
tts.py's HTTP API proxies /translate to it, because speech-tts itself may
not reach the internet (IPAddressDeny) and has no inference key.
"""
import argparse
import json
import logging
import re

from aiohttp import ClientSession, ClientTimeout, web

log = logging.getLogger("speech-translate")
LANGS = ("en", "de", "th")
MAX_TEXT = 500

PROMPT = """You translate short sentences for a text-to-speech voice preview.
Detect which of these languages the input is in: en (English), de (German), th (Thai).
Then give the sentence in all three languages. Keep the meaning, tone and register
(casual stays casual), keep names unchanged, write numbers the way a speaker of that
language would say them, no explanations.
The entry for the detected language is the input, unchanged.
Answer with JSON only: {"source": "en|de|th", "en": "...", "de": "...", "th": "..."}"""


def parse(content: str) -> dict:
    m = re.search(r"\{.*\}", content, re.S)
    if not m:
        raise ValueError("no JSON in model answer")
    d = json.loads(m.group(0))
    if d.get("source") not in LANGS or not all(isinstance(d.get(l), str) and d[l].strip() for l in LANGS):
        raise ValueError("incomplete answer")
    return {"source": d["source"], **{l: d[l].strip() for l in LANGS}}


def app(a) -> web.Application:
    key = open(a.key_file).read().strip()

    async def translate(req):
        try:
            b = await req.json()
        except Exception:
            return web.json_response({"error": "invalid JSON"}, status=400)
        text = " ".join(str((b or {}).get("text", "")).split())
        if not text or len(text) > MAX_TEXT:
            return web.json_response({"error": f"text must be 1..{MAX_TEXT} characters"}, status=400)
        body = {
            "model": a.model,
            "temperature": 0.2,
            "messages": [{"role": "system", "content": PROMPT}, {"role": "user", "content": text}],
            "chat_template_kwargs": {"enable_thinking": False},
        }
        try:
            async with ClientSession(timeout=ClientTimeout(total=60)) as s:
                async with s.post(a.base_url + "/chat/completions", json=body,
                                  headers={"Authorization": f"Bearer {key}"}) as r:
                    if r.status != 200:
                        raise RuntimeError(f"inference HTTP {r.status}")
                    out = parse((await r.json())["choices"][0]["message"]["content"])
        except Exception as e:
            log.warning("translate failed: %s", e)
            return web.json_response({"error": f"translation failed: {e}"}, status=502)
        out[out["source"]] = text
        log.info("translate %s: %s", out["source"], text)
        return web.json_response(out)

    w = web.Application(client_max_size=16 * 1024)
    w.add_routes([web.post("/translate", translate)])
    return w


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--model", default="qwen")
    ap.add_argument("--key-file", required=True)
    a = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    web.run_app(app(a), host="127.0.0.1", port=a.port, print=None, access_log=None)


if __name__ == "__main__":
    main()
