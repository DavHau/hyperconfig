#!/usr/bin/env bash
# fleet-brief-dispatch: the forced command (authorized_keys `command=`)
# of edi's fleet-brief user (./default.nix). Exactly three requests, by
# SSH_ORIGINAL_COMMAND, nothing else, no arguments:
#   send          the message on stdin -> fleet-telegram-send --mark-brief
#   send-nostamp  the same without the stamp (a brief without the digest:
#                 edi's own 09:30 digest still goes out)
#   digest-json   the warning digest as JSON (fleet-alert-digest --json)
# Each runs as root's fixed helper through sudo (one rule per verb).
# DISPATCH_SUDO / DISPATCH_ROOT are set by the Nix wrapper (the tests
# point them at a stub).
set -u
case "${SSH_ORIGINAL_COMMAND-}" in
  send | send-nostamp | digest-json)
    exec "$DISPATCH_SUDO" -n "$DISPATCH_ROOT" "$SSH_ORIGINAL_COMMAND"
    ;;
esac
echo "fleet-brief-dispatch: refused: only 'send' or 'send-nostamp' (message on stdin) or 'digest-json'" >&2
exit 2
