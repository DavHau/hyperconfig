#!/usr/bin/env nix-shell
#!nix-shell -i bash -p curl jq
# Pin ./claude-code-version to the latest @anthropic-ai/claude-code release
# on npm: the version the agents' `claude --version` stub reports.
set -euo pipefail

file="$(dirname "$0")/claude-code-version"
version=$(curl -fsS https://registry.npmjs.org/@anthropic-ai/claude-code/latest | jq -er .version)
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "unexpected npm version: $version" >&2
  exit 1
}
echo "$version" >"$file"
echo "claude-code-version: $version"
