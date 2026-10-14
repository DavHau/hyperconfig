#!/usr/bin/env bash
# Usage (repo root, logged-in Mullvad app on this machine):
#   nix shell nixpkgs#curl nixpkgs#jq nixpkgs#wireguard-tools \
#     -c bash modules/nixos/mullvad-egress/register.sh MACHINE
#
# Registers a new WireGuard device for MACHINE with the account of the local
# Mullvad app and stores its key and addresses as the clan vars
# mullvad-egress/privateKey (secret) and mullvad-egress/device (public). The
# account number, access token and private key only ever travel on stdin or
# through a pipe: never argv, never output. An account holds at most five
# devices; revoke one (`mullvad account revoke-device`) if registration says
# the account is full.
set -euo pipefail

machine=${1:?usage: register.sh MACHINE}
api=https://api.mullvad.net
if [ -e "vars/per-machine/$machine/mullvad-egress/device/value" ]; then
  echo "$machine already has a Mullvad device; revoke it and remove its vars first" >&2
  exit 1
fi

curl_api() { curl -sS --fail-with-body --max-time 20 -H 'content-type: application/json' "$@"; }

account=$(mullvad account get 2>/dev/null | sed -n 's/^Mullvad account:[[:space:]]*//p') || true
[[ $account =~ ^[0-9]+$ ]] || { echo "the local Mullvad app is not logged in" >&2; exit 1; }
# printf is a builtin: the number reaches curl on stdin, never in an argv.
token=$(printf '{"account_number":"%s"}' "$account" |
  curl_api -d @- "$api/auth/v1/token" | jq -er .access_token)
unset account
auth() { printf 'authorization: Bearer %s\n' "$token"; }

key=$(wg genkey)
device=$(jq -n --arg k "$(wg pubkey <<<"$key")" '{pubkey: $k, hijack_dns: false}' |
  curl_api -H @<(auth) -d @- "$api/accounts/v1/devices") ||
  { echo "registration failed (all five device slots used?): $device" >&2; exit 1; }
device_id=$(jq -er .id <<<"$device")
jq -e '.ipv4_address and .ipv6_address' <<<"$device" >/dev/null

# Storing failed: give the slot back rather than leave an unknown device.
trap 'curl_api -X DELETE -H @<(auth) "$api/accounts/v1/devices/$device_id" >/dev/null || true' ERR
export CLAN_NO_COMMIT=1
printf '%s' "$key" | clan vars set "$machine" mullvad-egress/privateKey
jq -c '{id, name, pubkey, ipv4_address, ipv6_address}' <<<"$device" |
  clan vars set "$machine" mullvad-egress/device
trap - ERR
echo "registered Mullvad device '$(jq -r .name <<<"$device")' for $machine"
