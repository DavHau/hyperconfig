# Render the initrd's wpa_supplicant.conf from the clan wifi vars.
# args: <network-name-file> <password-file> <output>
ssid_file=$1
psk_file=$2
out=$3

umask 0077
mkdir -p "$(dirname "$out")"

# Always write the file, even with no credentials: boot.initrd.secrets copies it
# during bootloader install, and a missing source aborts that with "failed to
# create initrd secrets" - i.e. no boot entry at all. A stub costs us wifi in
# the initrd; a missing file costs the machine its bootloader.
#
# Staged in the destination directory, not $TMPDIR: under nixos-install TMPDIR
# names a path on the installer that does not exist inside the chroot, so
# mktemp there fails and takes the whole activation snippet with it.
{
  echo "ctrl_interface=/run/wpa_supplicant"
  echo "update_config=0"
  if [ -r "$ssid_file" ] && [ -r "$psk_file" ]; then
    echo "network={"
    printf '\tssid="%s"\n' "$(cat "$ssid_file")"
    printf '\tpsk="%s"\n' "$(cat "$psk_file")"
    echo "}"
  else
    echo "initrd-wpa-conf: wifi vars unreadable, initrd gets no network block" >&2
  fi
} >"$out.tmp"
mv "$out.tmp" "$out"
