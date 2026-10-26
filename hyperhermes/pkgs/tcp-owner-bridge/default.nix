# The owner-checking per-connection bridge (./tcp-owner-bridge.rs explains
# why the check IS the access control). The core forwards run it for every
# root-held agent port; features that publish more owner-bound ports reach
# it as services.hyperhermes.tcpOwnerBridge.
{ pkgs }:
pkgs.writers.writeRustBin "hermes-tcp-owner-bridge" {
  rustcArgs = [
    "-O"
    "--edition"
    "2021"
  ];
} ./tcp-owner-bridge.rs
