# Render the initrd's wpa_supplicant.conf from the clan wifi vars.
# args: <network-name-file> <password-file> <output>
ssid_file=$1
psk_file=$2
out=$3

if [ ! -r "$ssid_file" ] || [ ! -r "$psk_file" ]; then
  echo "initrd-wpa-conf: wifi vars not readable yet, skipping" >&2
  exit 0
fi

umask 0077
mkdir -p "$(dirname "$out")"
tmp=$(mktemp)
{
  echo "ctrl_interface=/run/wpa_supplicant"
  echo "update_config=0"
  echo "network={"
  printf '\tssid="%s"\n' "$(cat "$ssid_file")"
  printf '\tpsk="%s"\n' "$(cat "$psk_file")"
  echo "}"
} >"$tmp"
mv "$tmp" "$out"
