# Services taken down for a critical, exploitable vulnerability that
# could not be fixed in time (./default.nix; policy:
# modules/nixos/infra-space/security-jobs/policy.md). One entry per
# machine and unit; remove it (push, deploy) to bring the service back.
#
#   som."searx.service" = {
#     reason = "CVE-2026-12345, unauthenticated RCE, no fixed release yet";
#     since = "2026-11-15";
#     undo = "remove this entry, push, deploy som";
#   };
{
}
