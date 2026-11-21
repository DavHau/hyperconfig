#!/data/data/com.termux/files/usr/bin/sh
# Run once in Termux (Dave's phone, docs/dave-phone.md section 2):
#   termux-setup-storage; sh /sdcard/Download/termux-hotspot-setup.sh
# Sets up Shizuku's rish in Termux, the hotspot command Automation calls,
# and lets Automation start Termux commands (allow-external-apps).
set -e
D=/sdcard/Download/hotspot-setup
mkdir -p ~/rish ~/bin ~/.termux
cp "$D/rish" "$D/rish_shizuku.dex" ~/rish/
chmod 700 ~/rish/rish
chmod 400 ~/rish/rish_shizuku.dex
cat > ~/bin/hotspot-off-if-idle <<'EOF'
#!/data/data/com.termux/files/usr/bin/sh
RISH_APPLICATION_ID=com.termux exec sh ~/rish/rish -c 'sh /data/local/tmp/hotspot-off-if-idle.sh'
EOF
chmod 700 ~/bin/hotspot-off-if-idle
touch ~/.termux/termux.properties
grep -q '^allow-external-apps' ~/.termux/termux.properties ||
  echo 'allow-external-apps = true' >> ~/.termux/termux.properties
termux-reload-settings 2>/dev/null || true
echo "Shizuku asks to allow Termux now: tap Allow."
RISH_APPLICATION_ID=com.termux sh ~/rish/rish -c id
