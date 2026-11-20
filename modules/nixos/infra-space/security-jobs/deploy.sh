# sec-job-deploy: the security jobs' deploy (policy rule 1: fix ->
# review -> land -> DEPLOY -> verify). Deploys exactly the rev the job
# pushed (a throwaway git worktree at that rev, never a workspace's
# state), refused unless it is an ancestor of origin/main, to the named
# machines with `clan machines update <m> --build-host localhost
# --target-host root@<m>.d`, the fleet's deploy path.
#
#   sec-job-deploy start RUN REV MACHINE...    detached; prints the unit
#   sec-job-deploy status RUN                  the status file
#   sec-job-deploy confirm RUN [MACHINE...]    the checks (below); no
#                                                 MACHINE: every machine
#                                                 of the run that started
#                                                 a switch and has no `ok`
#                                                 line (the resume)
#
# Detached: a transient user unit (systemd-run --user), so a dying
# client (a som switch restarts infra-space's gateway) leaves the deploy
# running; RUN/status gets `rev <sha>`, `build exit=<rc>`, `<m>
# built=<toplevel>`, `<m> offline|running|exit=<rc> current=<system>`,
# `<m> ok|rolled-back|check-failed`, `som held`, and a final `done`.
#
# Order: every machine's toplevel is built first, in ONE `sec-job-nix
# build` (--max-jobs 2 --cores 8); the machines other than som then
# switch in parallel; som (whose switch reloads this container and kills
# this unit) switches LAST and only when every other machine of the run
# shows `ok` (else `som held`, som untouched). After som's switch the
# resumed job runs `sec-job-deploy confirm RUN`.
#
# Rollback watchdog, per machine: the closure is copied to the target
# first (`nix copy`), then a transient timer is armed there
# (`systemd-run --on-active=10min`, unit sec-deploy-rollback) right
# before `clan machines update` switches it. When it fires it switches
# back to the generation that ran before, unless the deploy was
# confirmed. Confirmation and rollback race for one atomic marker
# (`mkdir /run/sec-deploy.decided`, its `by` file says who): the first
# one wins, the other gives way, so a machine is never reported `ok`
# after it rolled back. confirm takes the marker only when the machine
# answers ssh over the mesh, its /run/current-system IS the toplevel
# this run built, and, on the machine hosting pocket-id (it has a
# pocket-id.service), id.davhau.com's discovery URL answers 200;
# elsewhere pocket-id down is a `warn` line, not a rollback (that
# machine's switch cannot have caused it). A switch that cuts the mesh
# or sshd so reverts itself without anyone reaching the machine.
# exit=4 with a `failed:` list means units failed during the switch,
# maybe old unrelated ones: the system did switch.

# writeShellApplication sets -e; failures here are handled one by one.
set +e -uo pipefail
machines_ok=" @machines@ "
repo=@repo@
clan=/run/current-system/sw/bin/clan
jobnix=@jobNix@
run_root=@runRoot@
oidc=https://id.davhau.com/.well-known/openid-configuration
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10)

die() {
  echo "sec-job-deploy: $*" >&2
  exit 2
}
cmd=${1:-}
name=${2:-}
[ -n "$cmd" ] && [ -n "$name" ] || die "usage: sec-job-deploy start RUN REV MACHINE... | status RUN | confirm RUN [MACHINE...]"
if [ "$cmd" = run ]; then
  [ "${SEC_JOB_DEPLOY_INTERNAL:-}" = 1 ] || die "run is internal to sec-job-deploy start"
  dir=$name
  case "$dir" in "$run_root"/*) ;; *) die "internal log directory outside $run_root" ;; esac
else
  case "$name" in
    *[!A-Za-z0-9._-]* | "" | . | ..) die "RUN must be a plain [A-Za-z0-9._-] name" ;;
  esac
  dir=$run_root/$name
fi
shift 2

check_machine() {
  case "$machines_ok" in
    *" $1 "*) ;;
    *) die "not a deployable machine: $1 (one of:$machines_ok)" ;;
  esac
}

st() { echo "$*" >>"$dir/status"; }
built_of() { # the toplevel this run built for $1
  grep -E "^$1 built=/nix/store/" "$dir/status" | tail -n 1 | cut -d= -f2-
}

# On the target, read-only: current system, who took the marker, whether
# pocket-id runs there.
# shellcheck disable=SC2016 # runs on the target
probe_script='cur=$(readlink /run/current-system)
by=$(cat /run/sec-deploy.decided/by 2>/dev/null)
host=no
systemctl cat pocket-id.service >/dev/null 2>&1 && host=yes
echo "cur=$cur by=$by pocketid=$host"'
# On the target: take the marker for "ok" (stops the timer), or report
# that the rollback has it; then re-check the system did not move.
# shellcheck disable=SC2016 # runs on the target
take_script='want=$1
if mkdir /run/sec-deploy.decided 2>/dev/null; then
  echo ok >/run/sec-deploy.decided/by
  systemctl stop sec-deploy-rollback.timer 2>/dev/null
fi
by=$(cat /run/sec-deploy.decided/by 2>/dev/null)
[ "$by" = ok ] || { echo "by=$by"; exit 1; }
[ "$(readlink /run/current-system)" = "$want" ] || { echo moved; exit 1; }
echo confirmed'
# On the target: arm the rollback (refused while an earlier one is
# pending). It takes the marker first; if confirm has it, it does nothing.
# shellcheck disable=SC2016 # runs on the target
arm_script='prev=$1
if systemctl is-active -q sec-deploy-rollback.timer; then
  echo "a rollback from an earlier deploy is pending"
  exit 1
fi
rm -rf /run/sec-deploy.decided
systemctl reset-failed sec-deploy-rollback.service 2>/dev/null
systemd-run --unit=sec-deploy-rollback --on-active=10min --timer-property=AccuracySec=10s \
  /bin/sh -c "mkdir /run/sec-deploy.decided 2>/dev/null || exit 0; echo rollback >/run/sec-deploy.decided/by; /run/current-system/sw/bin/nix-env -p /nix/var/nix/profiles/system --set $prev; $prev/bin/switch-to-configuration switch"'

# The lock-out checks; on success the machine is confirmed (its rollback
# gives way). Prints one result: ok, rolled-back, not-switched ...,
# unreachable, pocket-id-down ..., error: ...
confirm() {
  local m=$1 want out code
  want=$(built_of "$m")
  if [ -z "$want" ]; then
    echo "error: no built toplevel recorded for $m"
    return 1
  fi
  out=$(timeout 30 ssh "${ssh_opts[@]}" "$m.d" bash -s <<<"$probe_script" 2>/dev/null)
  if [ -z "$out" ]; then
    echo unreachable
    return 1
  fi
  case "$out" in
    *" by=rollback "*)
      echo rolled-back
      return 1
      ;;
  esac
  case "$out" in
    "cur=$want "*) ;;
    *)
      echo "not-switched (${out%% by=*}, built $want)"
      return 1
      ;;
  esac
  code=$(curl -sS -o /dev/null -m 20 -w '%{http_code}' "$oidc" 2>/dev/null)
  if [ "$code" != 200 ]; then
    case "$out" in
      *" pocketid=yes")
        echo "pocket-id-down (HTTP $code, on its host)"
        return 1
        ;;
      *) st "$m warn $(date -u +%T): pocket-id answers HTTP $code (not hosted here; no rollback)" ;;
    esac
  fi
  out=$(timeout 30 ssh "${ssh_opts[@]}" "$m.d" bash -s -- "$want" <<<"$take_script" 2>/dev/null)
  case "$out" in
    confirmed) echo ok ;;
    *by=rollback*)
      echo rolled-back
      return 1
      ;;
    "")
      echo unreachable
      return 1
      ;;
    *)
      echo "error: $out"
      return 1
      ;;
  esac
}

# confirm, plus one status line; 0 when ok
confirm_line() {
  local m=$1 r
  r=$(confirm "$m")
  case "$r" in
    ok)
      st "$m ok $(date -u +%T)"
      return 0
      ;;
    rolled-back) st "$m rolled-back $(date -u +%T)" ;;
    unreachable | pocket-id-down*) st "$m check-failed $(date -u +%T): $r; rolls back within 10 min of the arm" ;;
    *) st "$m check-failed $(date -u +%T): $r" ;;
  esac
  return 1
}

case "$cmd" in
  status)
    cat -- "$dir/status"
    exit
    ;;
  confirm)
    [ -f "$dir/status" ] || die "no $dir/status"
    if [ $# = 0 ]; then
      mapfile -t todo < <(grep -E '^[a-z0-9-]+ running ' "$dir/status" | cut -d' ' -f1 | sort -u)
    else
      todo=("$@")
    fi
    rc=0
    for m in "${todo[@]}"; do
      check_machine "$m"
      if grep -qE "^$m ok " "$dir/status"; then
        echo "sec-job-deploy: $m already ok"
        continue
      fi
      if confirm_line "$m"; then
        echo "sec-job-deploy: $m confirmed"
      else
        echo "sec-job-deploy: $(grep -E "^$m " "$dir/status" | tail -n 1)" >&2
        rc=1
      fi
    done
    exit "$rc"
    ;;
  start)
    [ $# -ge 2 ] || die "usage: sec-job-deploy start RUN REV MACHINE..."
    rev=$1
    shift
    case "$rev" in
      *[!0-9a-f]* | "") die "REV must be a full commit id (the commit you pushed)" ;;
    esac
    [ ${#rev} = 40 ] || die "REV must be a full 40-character commit id"
    for m in "$@"; do check_machine "$m"; done
    umask 027
    [ ! -L "$dir" ] || die "$dir is a symlink"
    mkdir -p -- "$dir" || die "mkdir $dir"
    chmod 2750 "$dir" || die "chmod $dir"
    unit="sec-job-deploy-$(date -u +%Y%m%dT%H%M%S)"
    systemd-run --user --collect --unit="$unit" \
      --setenv=PATH="$PATH" --setenv=HOME=/home/infra --setenv=SEC_JOB_DEPLOY_INTERNAL=1 \
      "$0" run "$dir" "$rev" "$@" >&2 || die "systemd-run failed"
    echo "$unit"
    exit
    ;;
  run) ;;
  *) die "unknown command: $cmd" ;;
esac

# --- run (inside the transient unit)
rev=$1
shift
: >"$dir/status"
cd "$repo" || exit 1
git fetch -q origin || exit 1
if ! git merge-base --is-ancestor "$rev" origin/main; then
  st "refused: $rev is not an ancestor of origin/main"
  exit 1
fi
wt=$(mktemp -d "${TMPDIR:-/tmp}/sec-deploy.XXXXXX")
git worktree add -q --detach "$wt" "$rev" || exit 1
trap 'git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1; git -C "$repo" worktree prune' EXIT
st "rev $rev"
cd "$wt" || exit 1

# Online machines only; all toplevels in one build.
online=()
for m in "$@"; do
  if timeout 20 ssh "${ssh_opts[@]}" "$m.d" true 2>/dev/null; then
    online+=("$m")
  else
    st "$m offline"
  fi
done
if [ ${#online[@]} = 0 ]; then
  st "done $(date -u +%T)"
  exit 0
fi
attrs=()
for m in "${online[@]}"; do
  attrs+=(".#nixosConfigurations.$m.config.system.build.toplevel")
done
"$jobnix" build --no-link --json "${attrs[@]}" >"$dir/build.json" 2>"$dir/build.log"
rc=$?
st "build exit=$rc $(date -u +%T)"
if [ "$rc" != 0 ]; then
  st "done $(date -u +%T) (nothing switched: build failed)"
  exit 1
fi
# nix build --json lists the installables in their order
i=0
for m in "${online[@]}"; do
  top=$(jq -r ".[$i].outputs.out" "$dir/build.json")
  case "$top" in
    /nix/store/*) st "$m built=$top" ;;
    *)
      st "done $(date -u +%T) (nothing switched: no toplevel for $m in the build output)"
      exit 1
      ;;
  esac
  i=$((i + 1))
done

one() {
  local m=$1 rc failed cur prev want
  want=$(built_of "$m")
  prev=$(timeout 20 ssh "${ssh_opts[@]}" "$m.d" readlink -f /run/current-system 2>/dev/null)
  case "$prev" in
    /nix/store/*) ;;
    *)
      st "$m skipped: no current system read"
      return
      ;;
  esac
  # The closure first, so the 10 minutes cover only the switch.
  if ! NIX_SSHOPTS="${ssh_opts[*]}" "$jobnix" copy --to "ssh-ng://root@$m.d" "$want" >>"$dir/$m.log" 2>&1; then
    st "$m skipped: copying the closure failed (see $m.log)"
    return
  fi
  if ! timeout 30 ssh "${ssh_opts[@]}" "$m.d" bash -s -- "$prev" <<<"$arm_script" >>"$dir/$m.log" 2>&1; then
    st "$m skipped: arming the rollback timer failed (see $m.log; a pending rollback from an earlier deploy?)"
    return
  fi
  st "$m running $(date -u +%T) prev=$prev"
  NIX_CONFIG="max-jobs = @maxJobs@
cores = @cores@" "$clan" machines update "$m" --build-host localhost --target-host "root@$m.d" >>"$dir/$m.log" 2>&1
  rc=$?
  failed=$(grep -oE 'the following units failed: .*' "$dir/$m.log" | tail -1 | cut -d: -f2-)
  cur=$(timeout 20 ssh "${ssh_opts[@]}" "$m.d" readlink /run/current-system 2>/dev/null)
  st "$m exit=$rc $(date -u +%T) current=$cur${failed:+ failed:$failed}"
  confirm_line "$m"
}

# Everything but som in parallel; som last, and only if all others are ok.
others=()
self=
for m in "${online[@]}"; do
  if [ "$m" = som ]; then self=som; else others+=("$m"); fi
done
for m in "${others[@]}"; do one "$m" & done
wait
if [ -n "$self" ]; then
  notok=()
  for m in "${others[@]}"; do
    grep -qE "^$m ok " "$dir/status" || notok+=("$m")
  done
  if [ ${#notok[@]} -gt 0 ]; then
    st "som held $(date -u +%T): not every other machine is ok (${notok[*]}); som not deployed"
  else
    # its switch reloads this container: this unit may die here, and
    # the resumed job runs `sec-job-deploy confirm RUN`
    one som
  fi
fi
st "done $(date -u +%T)"
