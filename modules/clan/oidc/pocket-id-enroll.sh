# pocket-id-enroll <username|email>
#
# Prints a one-time login link (valid 1 h) for an account the oidc clan
# service declared. The person opens it and registers a passkey. Runs
# pocket-id's own CLI as the service user with the service's environment,
# so it reads the same database; the root-owned encryption key rides in
# as a systemd credential like it does for the service itself.
#
# POCKET_ID_BIN, POCKET_ID_ENV_FILE, POCKET_ID_ENCRYPTION_KEY_FILE and
# POCKET_ID_DATA_DIR are baked in by the module.

if [ $# -ne 1 ]; then
  echo "usage: pocket-id-enroll <username|email>" >&2
  exit 2
fi

# shellcheck disable=SC2016  # the $CREDENTIALS_DIRECTORY expansion belongs to the unit's shell
exec systemd-run --quiet --wait --pipe --collect \
  --property=User=pocket-id \
  --property=Group=pocket-id \
  --property=WorkingDirectory="$POCKET_ID_DATA_DIR" \
  --property=EnvironmentFile="$POCKET_ID_ENV_FILE" \
  --property=LoadCredential=encryption_key:"$POCKET_ID_ENCRYPTION_KEY_FILE" \
  /bin/sh -c 'ENCRYPTION_KEY_FILE=$CREDENTIALS_DIRECTORY/encryption_key exec "$0" one-time-access-token "$1"' \
  "$POCKET_ID_BIN" "$1"
