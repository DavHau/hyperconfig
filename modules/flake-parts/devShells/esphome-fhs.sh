venv="${ESPHOME_VENV:-$HOME/.cache/esphome-venv}"
marker="$venv/.esphome-$ESPHOME_PIN"
if [ ! -e "$marker" ]; then
  rm -rf "$venv"
  python3 -m venv "$venv"
  "$venv/bin/pip" install --quiet "esphome==$ESPHOME_PIN"
  touch "$marker"
fi
exec "$venv/bin/esphome" "$@"
