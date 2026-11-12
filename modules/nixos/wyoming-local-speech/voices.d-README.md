# Drop-in TTS voices (vit speech-tts)

Installed by modules/nixos/wyoming-local-speech (hyperconfig); edits to this
README are overwritten at the next service start.

Put one file per voice into the engine's directory here. Members of group
`speech-voices` (e.g. dave-hermes) may write; the directories are setgid,
so new files get that group. Make files group-readable (`chmod 644`): the
TTS service reads them as user `speech` via the group.

The server rescans this tree whenever a file changes (on the next request,
no restart). A bad file is skipped and logged (`journalctl -u speech-tts`),
never fatal. The voice id is `<engine>/<name>`; `<name>` must match
`[A-Za-z0-9][A-Za-z0-9_-]{0,63}` and must not equal a built-in voice name.

| engine dir    | voice file      | format                                                                 |
|---------------|-----------------|------------------------------------------------------------------------|
| `kokoro82/`   | `<name>.npy`    | float32 style pack shaped like a voices-v1.0.bin entry: `(510, 1, 256)` (or `(510, 256)`); English |
| `supertonic/` | `<name>.json`   | Supertonic 3 voice-style JSON, same layout as the built-in `voice_styles/F1.json` (`style_ttl` [1,50,256], `style_dp` [1,8,16]); de/en |
| `wayu_thai/`  | `<name>.npy`    | float32 ref_s vector, 256 values `(1, 256)`, as `onnx_infer.load_styles()` yields; Thai |

Optional sidecar with metadata, JSON object, all keys optional:
`<name>.json` (kokoro82, wayu_thai) or `<name>.meta.json` (all engines;
the only option for supertonic, whose voice file is already `.json`):

    {"label": "Warm narrator", "lang": "de", "speed": 0.95, "description": "..."}

- `lang`: string or list, within the engine's languages (kokoro82: en,
  supertonic: de/en, wayu_thai: th). Default: all of them.
- `speed`: 0.5..2.0, default 1.0. For wayu_thai, copy the roster speed of
  the speaker the style came from (data/seeds/roster.json).
- kokoro82 only: `"british": true` uses the en-gb G2P.

Example: a copy of a built-in Supertonic voice

    cp /var/lib/speech/models/supertonic-3/voice_styles/F2.json supertonic/my_f2.json
    echo '{"label": "My F2", "lang": "de"}' > supertonic/my_f2.meta.json
    chmod 644 supertonic/my_f2*

Test it (HTTP API on vit, localhost only):

    curl -s localhost:10201/voices | jq '.languages.de.voices[].id'
    curl -s -H 'Content-Type: application/json' localhost:10201/preview \
      -d '{"lang": "de", "voice": "supertonic/my_f2", "text": "Hallo, das ist ein Test."}' -o t.wav

Selecting it for Assist is `PUT /voices` (`{"de": "supertonic/my_f2"}`) or
the voice-picker page; the selection file itself is written by the API only.
Removing a file removes the voice; a selection pointing at a missing voice
falls back to the default for that language.
