#!/usr/bin/env bash

read -s passwd
echo "storing password..."
timeout 5 curl -su admin:$(cat /run/secrets/tasmota-pw) "http://192.168.20.31/cm?cmnd=var16+$passwd" > /dev/null || echo "storing password failed"
systemctl start automount
