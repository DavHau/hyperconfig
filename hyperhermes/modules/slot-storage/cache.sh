# slot-storage-cache <user> <group> <home>: bind <home>/.cache from
# /scratch/home/<user>/.cache. Root runs this in a /scratch every slot
# user can write (1777), so every step refuses a symlink in the way.

user=$1
group=$2
home=$3
src=/scratch/home/$user/.cache
dst=$home/.cache

log() { echo "slot-storage-cache: $*" >&2; }

if findmnt -rn --mountpoint "$dst" >/dev/null; then
  exit 0 # already a mount (the host's scratchPaths, or an earlier run)
fi
if ! findmnt -rn --mountpoint /scratch >/dev/null; then
  log "/scratch is not a mount from the host (slot storage off?); leaving $dst alone"
  exit 0
fi

# mkdir_owned <path> <mode> <owner> <group>: an existing one must be a
# real directory with that owner; a new one is made so.
mkdir_owned() {
  if [ -L "$1" ]; then
    log "$1 is a symlink; not binding $dst"
    exit 1
  fi
  if [ -d "$1" ]; then
    if [ "$(stat -c %U "$1")" != "$3" ]; then
      log "$1 is not owned by $3; not binding $dst"
      exit 1
    fi
  else
    install -d -m "$2" -o "$3" -g "$4" "$1"
  fi
}

mkdir_owned /scratch/home 0755 root root
mkdir_owned "/scratch/home/$user" 0700 "$user" "$group"
mkdir_owned "$src" 0700 "$user" "$group"

if [ -L "$dst" ]; then
  log "$dst is a symlink; not binding it"
  exit 1
fi
if [ -d "$dst" ] && [ -n "$(ls -A "$dst")" ]; then
  log "$dst holds data; not hiding it. Move it into $src (or delete it), then: systemctl restart slot-storage-cache-$user"
  exit 0
fi
mkdir_owned "$dst" 0700 "$user" "$group"
mount --bind "$src" "$dst"
