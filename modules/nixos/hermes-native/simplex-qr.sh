# shellcheck shell=bash
# cli.nix pastes this into a writeShellApplication (shebang + set -euo
# pipefail); the directive keeps a standalone lint honest.
#
# Show the SimpleX address of the caller's agent as a QR code.
# ADDRESS_FILE and AGENT_UNIT come from the case block cli.nix prepends.

if [ ! -e "$ADDRESS_FILE" ]; then
  echo "hermes-simplex-qr: no address published yet ($ADDRESS_FILE)" >&2
  if systemctl is-active --quiet "$AGENT_UNIT.service"; then
    # The publisher retries every 30s; a young daemon is the common case.
    echo "  $AGENT_UNIT runs; the simplex daemon may still be reaching its relay." >&2
    echo "  Wait, then run this again." >&2
  else
    echo "  $AGENT_UNIT is not running: systemctl status $AGENT_UNIT" >&2
  fi
  exit 1
fi

if [ ! -r "$ADDRESS_FILE" ]; then
  echo "hermes-simplex-qr: $ADDRESS_FILE is not readable by $(id -un)" >&2
  exit 1
fi

address=$(tr -d '[:space:]' <"$ADDRESS_FILE")
if [ -z "$address" ]; then
  echo "hermes-simplex-qr: $ADDRESS_FILE is empty" >&2
  echo "  The guest publishes the address atomically, so an empty file is a bug." >&2
  exit 1
fi

# Anything but a SimpleX link scans fine and then does nothing in the app.
case "$address" in
https://* | simplex:/*) ;;
*)
  echo "hermes-simplex-qr: $ADDRESS_FILE holds no SimpleX link:" >&2
  echo "  $address" >&2
  exit 1
  ;;
esac

# -m 4: UTF8 output packs two module rows per text line, so an odd row
# count (as at -m 1) drops the top quiet-zone row and cameras balk; -m 4
# pads to an even count. Verified by rasterizing and decoding (zbarimg).
qrencode -t UTF8 -m 4 -o - "$address"
echo
echo "$address"
