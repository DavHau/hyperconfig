#!/usr/bin/env bash
# The forced command of an agent-upload key on the agent's machine
# (./default.nix): sshd runs it as the agent for every connection with
# that key, the client's wish in SSH_ORIGINAL_COMMAND. Exactly two verbs:
#   rsync --server ...          rrsync, write-only, no deletes, symlinks
#                               stored munged (inert), rooted in
#                               the agent's uploads dir ($UPLOADS)
#   agent-upload-status <name>  stdin (<= 64 KiB JSON) becomes
#                               $STATUS_DIR/<name>.json, mode 0640
# Anything else is refused.
set -euo pipefail
cmd=${SSH_ORIGINAL_COMMAND-}
case "$cmd" in
  "rsync --server "*)
    exec "$RRSYNC" -wo -no-del -no-lock -munge "$UPLOADS"
    ;;
  "agent-upload-status "*)
    name=${cmd#agent-upload-status }
    if ! [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,99}$ ]]; then
      echo "agent-upload: bad name" >&2
      exit 2
    fi
    umask 0027
    tmp=$(mktemp "$STATUS_DIR/.$name.XXXXXX")
    head -c 65536 >"$tmp"
    chmod 0640 "$tmp"
    mv -f "$tmp" "$STATUS_DIR/$name.json"
    ;;
  *)
    echo "agent-upload: refused" >&2
    exit 1
    ;;
esac
