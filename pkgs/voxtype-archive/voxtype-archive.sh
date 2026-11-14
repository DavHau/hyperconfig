# voxtype-archive: file and replay the dictation takes the patched voxtype
# daemon leaves in $VOXTYPE_ARCHIVE_DIR/incoming/<id>/{take.wav,take.json}
# (./take-archive.patch). Layout after `ingest`:
#   <archive>/YYYY/MM/<id>.flac   lossless, 16 kHz mono 24-bit
#   <archive>/YYYY/MM/<id>.json   sidecar: time, host, settings, text
# Dirs 0700, files 0600. Module: modules/nixos/voxtype-archive.nix.

archive="${VOXTYPE_ARCHIVE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/voxtype-archive}"
umask 077

usage() {
  cat <<EOF
usage: voxtype-archive <command>
  ingest                      encode incoming takes to FLAC, file them by month
  replay <take> [--config F]  re-transcribe an archived take (.flac/.json/id)
                              with config F (default: the take's own config
                              file if it still exists, else the system one);
                              prints JSON: text, status, archived_raw_text,
                              archived_final_text
  list [N]                    the last N takes (default 20): id, secs, status, text
  stats                       count, total duration, size on disk
archive: $archive
EOF
}

# Park a take ingest can't handle, so the incoming directory empties (the
# path unit re-runs ingest as long as it isn't) and nothing is lost.
park() {
  echo "voxtype-archive: $2, parked in $archive/failed/" >&2
  mkdir -p "$archive/failed"
  chmod 0700 "$archive/failed"
  [ -L "$1" ] || chmod -R go= -- "$1"
  local to
  to="$archive/failed/$(basename "$1").$(date +%s)"
  mv -f -- "$1" "$to"
  touch -h -- "$to" # the 30-day cleanup counts from parking
}

ingest_one() {
  local dir="$1" id year month dest tmp
  id="$(basename "$dir")"
  [[ "$id" =~ ^[0-9]{8}T[0-9]{6}-[0-9]{3}$ ]] || { park "$dir" "bad id $id"; return 0; }
  [ -f "$dir/take.wav" ] && [ -f "$dir/take.json" ] || { park "$dir" "incomplete $id"; return 0; }
  year="${id:0:4}" month="${id:4:2}"
  dest="$archive/$year/$month"
  mkdir -p "$dest"
  chmod 0700 "$archive/$year" "$dest"
  tmp="$dest/.$id.flac.tmp"
  rm -f "$tmp"
  # --verify decodes the result again and compares it with the input;
  # flac refuses to finish on any mismatch.
  if ! flac --silent --best --verify --no-padding -o "$tmp" "$dir/take.wav" \
    || ! jq --arg flac "$id.flac" '.audio.file = $flac' "$dir/take.json" > "$dest/.$id.json.tmp"; then
    rm -f "$tmp" "$dest/.$id.json.tmp"
    park "$dir" "encoding $id failed"
    return 0
  fi
  # flac copies the input's mode; the daemon writes 0600, enforce it anyway.
  chmod 0600 "$tmp" "$dest/.$id.json.tmp"
  sync -- "$tmp" "$dest/.$id.json.tmp"
  mv -f "$dest/.$id.json.tmp" "$dest/$id.json"
  mv -f "$tmp" "$dest/$id.flac"
  rm -rf -- "$dir"
  echo "archived $year/$month/$id"
}

cmd_ingest() {
  local entry
  [ -d "$archive/incoming" ] || return 0
  chmod 0700 "$archive"
  # One ingest at a time (the path unit, a manual run).
  exec 9>> "$archive/.ingest.lock"
  flock 9
  shopt -s dotglob nullglob
  for entry in "$archive"/incoming/*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    if [ -d "$entry" ] && [ ! -L "$entry" ]; then
      ingest_one "$entry"
    else
      # Anything but a take dir would keep incoming/ non-empty, and the
      # path unit re-triggering until it hits its start limit.
      park "$entry" "not a take: $(basename "$entry")"
    fi
  done
  # Takes the daemon died while writing never leave .partial.
  if [ -d "$archive/.partial" ]; then
    find "$archive/.partial" -mindepth 1 -maxdepth 1 -mmin +1440 -exec rm -rf -- {} +
  fi
  # Parked takes are kept 30 days for a look, then dropped.
  if [ -d "$archive/failed" ]; then
    find "$archive/failed" -mindepth 1 -maxdepth 1 -mtime +30 -exec rm -rf -- {} +
  fi
}

resolve_take() {
  local t="$1" id
  case "$t" in
    *.flac | *.json)
      t="${t%.*}"
      ;;
  esac
  if [ -f "$t.flac" ]; then
    echo "$t"
    return
  fi
  id="$(basename "$t")"
  if [[ "$id" =~ ^[0-9]{8}T ]] && [ -f "$archive/${id:0:4}/${id:4:2}/$id.flac" ]; then
    echo "$archive/${id:0:4}/${id:4:2}/$id"
    return
  fi
  echo "no such take: $1" >&2
  exit 1
}

cmd_replay() {
  local take="" config="" base out archived_config
  while [ $# -gt 0 ]; do
    case "$1" in
      --config | -c) config="$2"; shift 2 ;;
      --config=*) config="${1#--config=}"; shift ;;
      *) take="$1"; shift ;;
    esac
  done
  [ -n "$take" ] || { usage >&2; exit 2; }
  base="$(resolve_take "$take")"
  if [ -z "$config" ]; then
    archived_config="$(jq -r '.config_file // empty' "$base.json")"
    config=/etc/xdg/voxtype/config.toml
    if [ -n "$archived_config" ] && [ -f "$archived_config" ]; then
      config="$archived_config"
    elif [ -n "$archived_config" ]; then
      echo "voxtype-archive: the take's config $archived_config is gone (garbage-collected?), using $config" >&2
    fi
  fi
  if [ "$(jq -r '.model_override // empty' "$base.json")" != "" ]; then
    echo "voxtype-archive: the take used hotkey model override $(jq -r .model_override "$base.json"); replay uses the config's model" >&2
  fi
  # global: the EXIT trap runs after this function's locals are gone
  tmpdir="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/voxtype-replay.XXXXXX")"
  trap 'rm -rf -- "$tmpdir"' EXIT
  flac --silent --decode -o "$tmpdir/take.wav" "$base.flac"
  # --json (added by take-archive.patch): progress on stderr, one JSON
  # object {status: ok|empty|vad_rejected, text, detected_language, vad}.
  out="$(voxtype -c "$config" transcribe --json "$tmpdir/take.wav")"
  jq -e 'type == "object" and has("status")' <<<"$out" > /dev/null \
    || { echo "voxtype-archive: unexpected output from voxtype transcribe: $out" >&2; exit 1; }
  if [ "$(jq -r .status <<<"$out")" = vad_rejected ]; then
    echo "voxtype-archive: VAD found no speech with this config, nothing transcribed" >&2
  fi
  jq -n --arg take "$base.flac" --arg config "$config" \
    --argjson out "$out" --slurpfile orig "$base.json" \
    '{take: $take, config: $config, status: $out.status, text: $out.text,
      detected_language: $out.detected_language, vad: $out.vad,
      archived_status: $orig[0].status, archived_raw_text: $orig[0].raw_text,
      archived_final_text: $orig[0].text}'
}

cmd_list() {
  local n="${1:-20}"
  find "$archive" -mindepth 3 -maxdepth 3 -name '*.json' -not -name '.*' 2>/dev/null \
    | sort | tail -n "$n" \
    | while read -r f; do
        jq -r --arg id "$(basename "$f" .json)" \
          '[$id, (.audio.duration_secs | floor | tostring) + "s", .status, (.text // .raw_text // "")] | @tsv' "$f"
      done
}

cmd_stats() {
  local count secs bytes
  count="$(find "$archive" -mindepth 3 -maxdepth 3 -name '*.flac' -not -name '.*' 2>/dev/null | wc -l)"
  secs="$(find "$archive" -mindepth 3 -maxdepth 3 -name '*.json' -not -name '.*' -print0 2>/dev/null \
    | xargs -0 -r jq -s 'map(.audio.duration_secs) | add // 0 | floor')"
  bytes="$(du -sb "$archive" 2>/dev/null | cut -f1)"
  echo "takes: $count"
  echo "audio: $(( ${secs:-0} / 60 )) min $(( ${secs:-0} % 60 )) s"
  echo "size:  $(( ${bytes:-0} / 1024 / 1024 )) MiB ($archive)"
}

case "${1:-}" in
  ingest) shift; cmd_ingest "$@" ;;
  replay) shift; cmd_replay "$@" ;;
  list) shift; cmd_list "$@" ;;
  stats) shift; cmd_stats "$@" ;;
  -h | --help | help) usage ;;
  *) usage >&2; exit 2 ;;
esac
