usage() {
  echo "usage: prune-gcroots --delete-older-than AGE [--dry-run]" >&2
  echo "  AGE: <N>d | <N>h | <N>w  (e.g. 30d)" >&2
  exit 1
}

age=""
dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --delete-older-than) age="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) usage ;;
  esac
done
[ -n "$age" ] || usage

case "$age" in
  *d) secs=$(( ${age%d} * 86400 )) ;;
  *h) secs=$(( ${age%h} * 3600 )) ;;
  *w) secs=$(( ${age%w} * 604800 )) ;;
  *) echo "bad age spec: $age" >&2; usage ;;
esac

now=$(date +%s)
cutoff=$(( now - secs ))
auto=/nix/var/nix/gcroots/auto
deleted=0 kept=0

remove() { # $1=link $2=reason $3=target
  if [ "$dry_run" = 1 ]; then
    echo "would delete ($2): $3"
  else
    rm -f -- "$1"
    echo "deleted ($2): $3"
  fi
  deleted=$(( deleted + 1 ))
}

for link in "$auto"/*; do
  [ -L "$link" ] || continue
  target=$(readlink -- "$link")

  if [ ! -e "$target" ]; then
    remove "$link" dangling "$target"
    continue
  fi

  case "$target" in
    */.direnv/*)
      direnv=${target%%/.direnv/*}/.direnv
      # last load: newest atime/mtime among the cached rc files
      last=0
      for rc in "$direnv"/*.rc; do
        [ -e "$rc" ] || continue
        a=$(stat -c %X -- "$rc")
        m=$(stat -c %Y -- "$rc")
        [ "$a" -gt "$last" ] && last=$a
        [ "$m" -gt "$last" ] && last=$m
      done
      # no rc files: fall back to the auto link's own mtime
      if [ "$last" = 0 ]; then
        last=$(stat -c %Y -- "$link")
      fi
      if [ "$last" -lt "$cutoff" ]; then
        remove "$link" "devshell unused" "$target"
      else
        kept=$(( kept + 1 ))
      fi
      ;;
    *)
      last=$(stat -c %Y -- "$link")
      if [ "$last" -lt "$cutoff" ]; then
        remove "$link" "link too old" "$target"
      else
        kept=$(( kept + 1 ))
      fi
      ;;
  esac
done

verb=deleted; [ "$dry_run" = 1 ] && verb="would delete"
echo "$verb: $deleted, kept: $kept"
[ "$deleted" -gt 0 ] && [ "$dry_run" = 0 ] && \
  echo "roots removed; run nix-collect-garbage (or fast-nix-gc) to free the store paths"
exit 0
