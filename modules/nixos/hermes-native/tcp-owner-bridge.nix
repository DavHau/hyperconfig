# The owner-checking per-connection bridge (./tcp-owner-bridge.rs explains
# why the check IS the access control). Used by ./forwards.nix (dashboard,
# Camofox) and ../hermes-agents-serve.nix (serve ports).
{ pkgs }:
pkgs.writers.writeRustBin "hermes-tcp-owner-bridge" {
  rustcArgs = [
    "-O"
    "--edition"
    "2021"
  ];
} ./tcp-owner-bridge.rs
