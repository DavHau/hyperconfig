# remote: an agent's CLI for its ssh targets (./remotes.nix). Every
# remote command travels base64-encoded inside one fixed, quote-free ssh
# command line, so nothing the caller passes is ever quoted twice; data
# (put) rides stdin. One ssh master connection per target, kept 10 min.
# REMOTE_TARGETS: the JSON the module writes (targets, their commands).

: "${REMOTE_TARGETS:?remote: REMOTE_TARGETS is not set}"
OUT_DIR=${TMPDIR:-/tmp}/remote
CM_DIR=${XDG_RUNTIME_DIR:-$HOME/.ssh}
PERSIST=600
MAX_SCRIPT=120000

die() {
  echo "remote: $*" >&2
  exit 2
}

usage() {
  cat <<'EOF'
remote: run commands and move files on this agent's ssh targets, without
nested quoting.

  remote list
      The targets, their working dir, scratch dir and extra commands.
  (`remote run TARGET ...` is the same as `remote TARGET run ...`; so for
  put, get, help and close.)
  remote TARGET run [--cwd DIR] [--timeout S] [--max-lines N] -- CMD [ARG...]
      Run one command there, its words passed exactly (no remote shell:
      for pipes use `-- bash -c '...'` or --script). DIR: relative to the
      remote home (default: the target's cwd). S default 280, N 120.
  remote TARGET run [--cwd DIR] [--timeout S] [--max-lines N] --script FILE [ARG...]
      Run a local bash script there (FILE `-`: stdin), ARGs as $1...
      Output (stdout+stderr) is capped to N lines (head and tail); the
      full output is kept in a local file whose path is printed. The exit
      code is the command's (124: timed out).
  remote TARGET put LOCAL [REMOTE]
      Copy a file or directory there. A relative REMOTE (default: LOCAL's
      name) is under the target's scratch dir. Prints the remote path.
  remote TARGET get REMOTE [LOCAL]
      Copy a file or directory back. A relative REMOTE is under the scratch
      dir; LOCAL defaults to $TMPDIR/remote/get/<name>. Prints the path.
  remote TARGET COMMAND [ARG...]
      One of the target's own commands (see `remote TARGET help`); takes
      --timeout S and --max-lines N before its arguments, like run.
  remote TARGET help
      The target's description and its commands' help.
  remote TARGET close
      Close the shared ssh connection (it closes itself after 10 idle min).
EOF
}

jqt() { jq -er "$@" "$REMOTE_TARGETS"; }

# The remote bash for script text $1: decoded there from base64, so the ssh
# command line is the same quote-free words for any content and any login
# shell (sh, bash, fish).
wrap() {
  local b64
  b64=$(printf '%s' "$1" | base64 -w0)
  [ ${#b64} -le $MAX_SCRIPT ] || die "script too large to send inline; put it, then run it"
  printf "bash -c 'eval \"\$(echo %s | base64 -d)\"'" "$b64"
}

q() { printf '%q' "$1"; }
qargs() {
  local a
  for a in "$@"; do printf ' %q' "$a"; done
}
# POSIX shell quoting (for a command a remote parser splits with shlex).
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

load_target() {
  TARGET=$1
  jq -e --arg t "$TARGET" '.targets | has($t)' "$REMOTE_TARGETS" >/dev/null ||
    die "no target '$TARGET' (remote list)"
  HOST=$(jqt --arg t "$TARGET" '.targets[$t].host')
  CWD=$(jqt --arg t "$TARGET" '.targets[$t].cwd')
  SCRATCH=$(jqt --arg t "$TARGET" '.targets[$t].scratch')
  CM_PATH=$CM_DIR/remote-cm-%C
  SSH=(ssh -o BatchMode=yes -o ControlMaster=no -o "ControlPath=$CM_PATH")
}

# The master, once (under a lock, so parallel calls don't race); if it
# can't start, plain connections follow and show the real error.
connect() {
  mkdir -p "$CM_DIR" && chmod 0700 "$CM_DIR"
  (
    flock 9
    if ! ssh -o "ControlPath=$CM_PATH" -O check "$HOST" >/dev/null 2>&1; then
      timeout 30 ssh -o BatchMode=yes -o ControlMaster=yes -o "ControlPath=$CM_PATH" \
        -o "ControlPersist=$PERSIST" -f -N "$HOST" </dev/null >/dev/null 2>&1 || true
    fi
  ) 9>"$CM_DIR/remote-cm.lock"
  ssh -o "ControlPath=$CM_PATH" -O check "$HOST" >/dev/null 2>&1 ||
    SSH=(ssh -o BatchMode=yes -o ControlPath=none)
}

# Run script $1 there, stdin closed, output capped to $3 lines, the whole
# of it in a local file; $2: seconds (the local guard adds 30).
run_capped() {
  local script=$1 limit=$2 max=$3 out rc=0 n
  mkdir -p "$OUT_DIR/out" && chmod 0700 "$OUT_DIR" "$OUT_DIR/out"
  out=$OUT_DIR/out/$(date +%Y%m%d-%H%M%S)-$$-$TARGET.txt
  local cmd
  cmd=$(wrap "$script") || exit 2
  timeout $((limit + 30)) "${SSH[@]}" "$HOST" "$cmd" </dev/null >"$out" 2>&1 || rc=$?
  n=$(wc -l <"$out")
  if [ "$n" -le "$max" ]; then
    cat "$out"
  else
    head -n $((max / 4)) "$out"
    echo "[remote: ... $((n - max)) lines omitted ...]"
    tail -n $((max - max / 4)) "$out"
  fi
  echo "[remote: $n lines, exit $rc; full output: $out]"
  return "$rc"
}

number() { [[ $2 =~ ^[0-9]+$ ]] || die "$1 takes a number, got '${2:-}'"; }

cmd_run() {
  local cwd=$CWD limit=280 max=120 body="" have_script=""
  while [ $# -gt 0 ]; do
    case $1 in
      --cwd) [ -n "${2:-}" ] || die "--cwd needs a dir"; cwd=$2; shift 2 ;;
      --timeout) number "$1" "${2:-}"; limit=$2; shift 2 ;;
      --max-lines) number "$1" "${2:-}"; max=$2; shift 2 ;;
      --script)
        [ -n "${2:-}" ] || die "--script needs a file"
        if [ "$2" = - ]; then body=$(cat); else body=$(cat -- "$2") || exit 2; fi
        have_script=1; shift 2; break ;;
      --) shift; break ;;
      *) die "run: unknown option '$1' (the command goes after --)" ;;
    esac
  done
  local exe
  if [ -n "$have_script" ]; then
    exe="bash -c \"\$(echo $(printf '%s' "$body" | base64 -w0) | base64 -d)\" remote-script$(qargs "$@")"
  else
    [ $# -gt 0 ] || die "run: no command (remote TARGET run -- CMD ARG...)"
    exe=$(qargs "$@")
  fi
  connect
  run_capped "cd -- $(q "$cwd") && exec timeout -k 5 $limit $exe" "$limit" "$max"
}

resolve() {
  case $1 in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$SCRATCH" "$1" ;;
  esac
}

cmd_put() {
  [ $# -ge 1 ] && [ $# -le 2 ] || die "put LOCAL [REMOTE]"
  local src=$1 dest
  [ -e "$src" ] || die "put: no $src"
  dest=$(resolve "${2:-$(basename -- "$src")}")
  local cmd
  if [ -d "$src" ]; then
    cmd=$(wrap "mkdir -p -m 0700 -- $(q "$SCRATCH") && mkdir -p -- $(q "$dest") && tar -C $(q "$dest") -xf -") || exit 2
  else
    cmd=$(wrap "mkdir -p -m 0700 -- $(q "$SCRATCH") && mkdir -p -- \"\$(dirname -- $(q "$dest"))\" && cat > $(q "$dest.part") && mv -f -- $(q "$dest.part") $(q "$dest")") || exit 2
  fi
  connect
  if [ -d "$src" ]; then
    tar -C "$src" -cf - . | "${SSH[@]}" "$HOST" "$cmd"
  else
    "${SSH[@]}" "$HOST" "$cmd" <"$src"
  fi || die "put failed"
  echo "$dest"
}

cmd_get() {
  [ $# -ge 1 ] && [ $# -le 2 ] || die "get REMOTE [LOCAL]"
  local src dest kind
  src=$(resolve "$1")
  dest=${2:-$OUT_DIR/get/$(basename -- "$src")}
  local probe tarcmd catcmd
  probe=$(wrap "if [ -d $(q "$src") ]; then echo dir; elif [ -f $(q "$src") ]; then echo file; else echo none; fi") || exit 2
  tarcmd=$(wrap "tar -C $(q "$src") -cf - .") || exit 2
  catcmd=$(wrap "cat -- $(q "$src")") || exit 2
  connect
  kind=$("${SSH[@]}" "$HOST" "$probe" </dev/null)
  case $kind in
    dir)
      mkdir -p -- "$dest"
      "${SSH[@]}" "$HOST" "$tarcmd" </dev/null | tar -C "$dest" -xf - ;;
    file)
      mkdir -p -- "$(dirname -- "$dest")"
      "${SSH[@]}" "$HOST" "$catcmd" </dev/null >"$dest.part" &&
        mv -f -- "$dest.part" "$dest" ;;
    *) die "get: no file or directory $src on $TARGET" ;;
  esac || die "get failed"
  echo "$dest"
}

cmd_help() {
  jqt --arg t "$TARGET" '.targets[$t] |
    "\($t): \(.description)\nhost \(.host), cwd ~/\(.cwd), scratch \(.scratch)\n" +
    ([.commands | to_entries[] | "\nremote \($t) \(.key) \(.value.usage)\n\(.value.help | gsub("(?m)^"; "    "))"] | join(""))'
}

# A command from the target's table: `words` (its argv prefix, then the
# caller's words), `joined` (the prefix, then the caller's words as ONE
# POSIX-quoted string, for a remote that splits it itself, as ssh's
# forced commands do), or `script` (a script file of the module, run there
# by its interpreter with the caller's words as arguments).
cmd_table() {
  local name=$1 kind limit max=120 prefix=() fixed=() w joined="" exe
  shift
  kind=$(jqt --arg t "$TARGET" --arg c "$name" '.targets[$t].commands[$c].kind')
  limit=$(jqt --arg t "$TARGET" --arg c "$name" '.targets[$t].commands[$c].timeout')
  while [ $# -gt 0 ]; do
    case $1 in
      --timeout) number "$1" "${2:-}"; limit=$2; shift 2 ;;
      --max-lines) number "$1" "${2:-}"; max=$2; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  mapfile -t prefix < <(jq -r --arg t "$TARGET" --arg c "$name" '.targets[$t].commands[$c].prefix[]' "$REMOTE_TARGETS")
  case $kind in
    words) exe="$(qargs "${prefix[@]}" "$@")" ;;
    joined)
      for w in "$@"; do joined+="${joined:+ }$(sq "$w")"; done
      exe="$(qargs "${prefix[@]}" "$joined")" ;;
    script)
      local file
      file=$(jqt --arg t "$TARGET" --arg c "$name" '.targets[$t].commands[$c].script')
      mapfile -t fixed < <(jq -r --arg t "$TARGET" --arg c "$name" '.targets[$t].commands[$c].args[]' "$REMOTE_TARGETS")
      exe="$(qargs "${prefix[@]}") -c \"\$(echo $(base64 -w0 <"$file") | base64 -d)\"$(qargs "${fixed[@]}" "$@")" ;;
    *) die "command $name has an unknown kind '$kind'" ;;
  esac
  connect
  run_capped "cd -- $(q "$CWD") && exec timeout -k 5 $limit $exe" "$limit" "$max"
}

case ${1:-} in
  "" | -h | --help) usage; exit 0 ;;
  help) [ -n "${2:-}" ] || { usage; exit 0; } ;;
  list)
    jq -r '.targets | to_entries[] | "\(.key)\t\(.value.host)\tcwd ~/\(.value.cwd)\tscratch \(.value.scratch)\tcommands: \(.value.commands | keys | join(" "))\t\(.value.description)"' "$REMOTE_TARGETS"
    exit 0 ;;
esac
# `remote VERB TARGET ...` and `remote TARGET VERB ...` both work.
case $1 in
  run | put | get | help | close) [ -n "${2:-}" ] || die "$1 needs a target (remote list)"; set -- "$2" "$1" "${@:3}" ;;
esac
load_target "$1"
sub=${2:-help}
shift $(($# < 2 ? $# : 2))
case $sub in
  run) cmd_run "$@" ;;
  put) cmd_put "$@" ;;
  get) cmd_get "$@" ;;
  help | -h | --help) cmd_help ;;
  close) ssh -o "ControlPath=$CM_PATH" -O exit "$HOST" 2>&1 || true ;;
  *)
    jq -e --arg t "$TARGET" --arg c "$sub" '.targets[$t].commands | has($c)' "$REMOTE_TARGETS" >/dev/null ||
      die "$TARGET has no command '$sub' (remote $TARGET help)"
    cmd_table "$sub" "$@" ;;
esac
