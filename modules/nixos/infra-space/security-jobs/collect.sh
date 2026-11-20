# sec-collect: the security jobs' read-only collectors, run as infra through
# sudo. RUN is validated and output goes under the fixed group-readable root
# @runRoot@/RUN (0750/0640); the caller chooses no path. Nothing on a machine
# is changed (ssh commands are read-only listings).
#
#   sec-collect inventory RUN [MACHINE...]   packages + vulnix per machine
#   sec-collect exposure RUN [MACHINE...]    listeners, nft, declared firewall
#   sec-collect snapshot RUN [MACHINE...]    tripwire state (current system,
#                                            authorized keys, nft hashes)
#
# MACHINE defaults to @machines@ and is restricted to that list. Evaluation
# uses infra's checkout at @repo@.
#
# inventory: the system a machine RUNS (/run/current-system over ssh),
# else main's toplevel (eval) for a machine that is offline, marked as
# such. Its closure's names and versions (`pname<TAB>version`, from the
# store path names) go to <m>.pkgs, and `vulnix -j -C <system>` (NVD
# data cached in ~/.cache/vulnix) to <m>.vulnix.json. A live system not in
# som's store is listed over ssh (`nix-store -qR` on the machine) and
# scanned from main's toplevel instead, marked `vulnix-from=main`.
#
# exposure: per machine `ss -tulpnH` (live listeners), `nft -s list
# ruleset` (or iptables-save), and the declared side by eval:
# networking.firewall.{enable,allowedTCPPorts,allowedUDPPorts,
# allowedTCPPortRanges,interfaces,trustedInterfaces}, openssh settings.

# writeShellApplication sets -e; failures here are handled one by one.
set +e -uo pipefail

machines=(@machines@)
all_machines=" @machines@ "
run_root=@runRoot@
repo=@repo@
ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

die() {
  echo "sec-collect: $*" >&2
  exit 2
}
[ $# -ge 2 ] || die "usage: sec-collect inventory|exposure|snapshot RUN [MACHINE...]"
cmd=$1
run=$2
shift 2
case "$run" in *[!A-Za-z0-9._-]* | "" | . | ..) die "RUN must be a plain [A-Za-z0-9._-] name" ;; esac
out=$run_root/$run
[ $# -gt 0 ] && machines=("$@")
for m in "${machines[@]}"; do
  case "$all_machines" in *" $m "*) ;; *) die "not a deployable machine: $m" ;; esac
done
umask 027
[ ! -L "$out" ] || die "$out is a symlink"
mkdir -p -- "$out" || die "mkdir $out failed"
chmod 2750 "$out" || die "chmod $out failed"
cd "$repo" || die "no infra checkout at $repo"
[ -f flake.nix ] || die "no flake.nix in $repo"

on() { timeout 120 ssh "${ssh_opts[@]}" "$1.d" "$2"; }
reachable() { timeout 20 ssh "${ssh_opts[@]}" "$1.d" true 2>/dev/null; }

# store path names -> pname<TAB>version (the last -<digit>... is the version)
names() {
  sed -E 's|^/nix/store/[a-z0-9]{32}-||' | grep -Ev '\.(drv|patch|sh|tar\..*|zip)$|-(source|doc|man|dev|info|completions)$' |
    sed -nE 's/^(.+)-([0-9][^-]*.*)$/\1\t\2/p' | sort -u
}

eval_attr() {
  "$NIX" eval --raw ".#nixosConfigurations.$1.config.system.build.toplevel$2" 2>/dev/null
}

inventory() {
  local m=$1 sys from="live" main
  if reachable "$m"; then
    sys=$(on "$m" 'readlink /run/current-system') || sys=
  else
    sys=
  fi
  if [ -z "$sys" ]; then
    from="main-offline"
    sys=$(eval_attr "$m" .outPath) || {
      echo "$m: FAIL no live system and no eval"
      return
    }
  fi
  echo "$sys" >"$out/$m.system"
  if "$NIX" path-info "$sys" >/dev/null 2>&1; then
    nix-store -qR "$sys" | names >"$out/$m.pkgs"
    vulnix -j -C "$sys" >"$out/$m.vulnix.json" 2>"$out/$m.vulnix.err"
  else
    # live system not in this store: names from the machine, vulnix on
    # main's toplevel derivation (close, not exact: say so)
    on "$m" "nix-store -qR $sys" | names >"$out/$m.pkgs"
    main=$(eval_attr "$m" .drvPath)
    from="$from,vulnix-from=main"
    vulnix -j "$main" >"$out/$m.vulnix.json" 2>"$out/$m.vulnix.err"
  fi
  [ -s "$out/$m.vulnix.json" ] || echo '[]' >"$out/$m.vulnix.json"
  echo "$m: $from $(wc -l <"$out/$m.pkgs") packages, $(jq length "$out/$m.vulnix.json") vulnix entries"
}

declared() {
  "$NIX" eval --json ".#nixosConfigurations.$1.config" --apply 'c: {
    firewall = { inherit (c.networking.firewall) enable allowedTCPPorts allowedUDPPorts allowedTCPPortRanges allowedUDPPortRanges trustedInterfaces; interfaces = builtins.mapAttrs (_: i: { inherit (i) allowedTCPPorts allowedUDPPorts; }) c.networking.firewall.interfaces; };
    nftables = c.networking.nftables.enable;
    openssh = { inherit (c.services.openssh) enable ports openFirewall; settings = { inherit (c.services.openssh.settings) PasswordAuthentication PermitRootLogin KbdInteractiveAuthentication; }; };
  }' 2>"$out/$1.declared.err"
}

exposure() {
  local m=$1
  declared "$m" >"$out/$m.declared.json" || echo "$m: declared: eval failed"
  if ! reachable "$m"; then
    echo "$m: offline"
    return
  fi
  on "$m" 'ss -tulpnH' >"$out/$m.ss" 2>&1
  on "$m" 'nft -s list ruleset 2>/dev/null || iptables-save' >"$out/$m.nft" 2>&1
  echo "$m: $(wc -l <"$out/$m.ss") listeners, $(wc -l <"$out/$m.nft") ruleset lines"
}

snapshot() {
  local m=$1
  if ! reachable "$m"; then
    echo "$m offline" >>"$out/snapshot"
    return
  fi
  {
    echo "$m system $(on "$m" 'readlink /run/current-system')"
    echo "$m keys $(on "$m" 'cat /etc/ssh/authorized_keys.d/* /root/.ssh/authorized_keys 2>/dev/null | sha256sum' | cut -c1-16)"
    echo "$m nft $(on "$m" 'nft -s list ruleset 2>/dev/null | sha256sum' | cut -c1-16)"
  } >>"$out/snapshot"
}

case "$cmd" in
  inventory) for m in "${machines[@]}"; do inventory "$m"; done ;;
  exposure) for m in "${machines[@]}"; do exposure "$m"; done ;;
  snapshot)
    : >"$out/snapshot"
    echo "main $(git ls-remote origin refs/heads/main | cut -f1)" >>"$out/snapshot"
    for m in "${machines[@]}"; do snapshot "$m"; done
    sort -o "$out/snapshot" "$out/snapshot"
    cat "$out/snapshot"
    ;;
  *) die "unknown subcommand: $cmd" ;;
esac
