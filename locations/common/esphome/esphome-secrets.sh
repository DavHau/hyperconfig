#!/usr/bin/env bash
# Write an ESPHome directory's gitignored secrets.yaml from its clan vars
# (modules/nixos/esphome-secrets.nix).
#
# Usage:
#   esphome-secrets.sh <esphome-dir>
# e.g.
#   locations/common/esphome/esphome-secrets.sh locations/casa/esphome
#
# locations/<loc>/esphome reads generator esphome-<loc>, machines/<m>/esphome
# reads esphome-<m>, both through amy (the machine that imports the module).
# Every file of the generator becomes the top-level key of the same name,
# public ones (tang_adv, tang_thp) included: ESPHome ignores keys no config
# asks for, and the thp is then at hand for tang-check.sh.
#
# The file list comes from `nix eval` of the generator's declared files: exact,
# machine-readable, and touches no secret (`clan vars list` prints every var of
# amy, public values inline, for us to parse). Values are written as JSON
# strings, which are valid YAML double-quoted scalars whatever they contain.
# The file is replaced atomically, mode 0600; re-run after changing a var.
#
# locations/common/esphome gets no secrets.yaml: !secret in its packages falls
# back to the including device's directory.
#
# Needs nix, clan and jq (the repo's devshell).

set -euo pipefail

die() { printf '%s\n' "$*" >&2; exit 1; }
[[ $# -eq 1 ]] || die "usage: $0 <esphome-dir>"

root=$(cd "$(dirname "$0")/../../.." && pwd)
dir=$(cd "$1" && pwd)
rel=${dir#"$root"/}
case $rel in
locations/common/esphome)
    die "$rel holds shared packages; their !secret values come from the device's directory" ;;
locations/*/esphome | machines/*/esphome)
    owner=${rel#*/}
    owner=${owner%/esphome} ;;
*)
    die "$dir is not locations/<location>/esphome or machines/<machine>/esphome in $root" ;;
esac
[[ $owner != */* ]] || die "$rel: expected exactly one directory between ${rel%%/*}/ and /esphome"
generator=esphome-$owner

cd "$root"
names=$(nix eval --json ".#nixosConfigurations.amy.config.clan.core.vars.generators.\"$generator\".files" \
    --apply builtins.attrNames) || die "no generator $generator in amy's config (modules/nixos/esphome-secrets.nix)"
mapfile -t files < <(jq -r '.[]' <<<"$names")
[[ ${#files[@]} -gt 0 ]] || die "generator $generator declares no files"

umask 077
tmp=$(mktemp "$dir/.secrets.yaml.XXXXXX")
trap 'rm -f "$tmp"' EXIT
{
    echo "# Written by locations/common/esphome/esphome-secrets.sh from clan vars"
    echo "# generator $generator; edit the vars, not this file."
    for f in "${files[@]}"; do
        printf '%s: ' "$f"
        clan vars get amy "$generator/$f" | jq -Rs 'sub("\n+$"; "")'
    done
} >"$tmp"
mv -f "$tmp" "$dir/secrets.yaml"
trap - EXIT
echo "wrote $rel/secrets.yaml (${#files[@]} keys from $generator)"
