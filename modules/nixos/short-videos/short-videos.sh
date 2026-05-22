#!/usr/bin/env bash
# List video files in DIR (default: .) whose duration is below MAX_SECONDS
# (default: 30). Non-recursive.
set -euo pipefail

max=30
recursive=0

usage() {
  cat <<EOF
usage: short-videos [-d MAX_SECONDS] [-r] [PATH]

List video files shorter than MAX_SECONDS (default: 30) in PATH (default: .).

  -d SECONDS  duration threshold in seconds (float allowed)
  -r          recurse into subdirectories
  -h          show this help
EOF
}

while getopts "d:rh" opt; do
  case "$opt" in
    d) max=$OPTARG ;;
    r) recursive=1 ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

path=${1:-.}

if [[ ! -d $path ]]; then
  echo "short-videos: not a directory: $path" >&2
  exit 2
fi

if (( recursive )); then
  find_args=(-type f)
else
  find_args=(-maxdepth 1 -type f)
fi

while IFS= read -r -d '' f; do
  codec=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_type -of csv=p=0 -- "$f" 2>/dev/null || true)
  [[ $codec == video ]] || continue

  dur=$(ffprobe -v error -show_entries format=duration \
    -of csv=p=0 -- "$f" 2>/dev/null || true)
  [[ -n $dur && $dur != N/A ]] || continue

  if awk -v d="$dur" -v m="$max" 'BEGIN { exit !(d+0 < m+0) }'; then
    printf '%s\t%.2fs\n' "$f" "$dur"
  fi
done < <(find "$path" "${find_args[@]}" -print0)
