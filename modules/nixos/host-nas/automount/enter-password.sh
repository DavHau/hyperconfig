#!/usr/bin/env bash

read -s passwd
timeout 5 curl -su admin:$(cat /run/secrets/tasmota-pw) "http://192.168.178.21/cm?cmnd=var16+$passwd" > /dev/null || echo "storing password failed"
systemctl start automount
