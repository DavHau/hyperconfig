#!/usr/bin/env bash

read -s passwd
touch /run/passwd_enc || true
chown root /run/passwd_enc
chmod 600 /run/passwd_enc
echo $passwd > /run/passwd_enc
echo "password stored in /run/passwd_enc"
timeout 5 ssh root@10.99.99.2 "echo $passwd > /tmp/passwd_enc" || echo "storing password on raspi failed"
