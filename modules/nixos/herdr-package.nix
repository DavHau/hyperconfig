# herdr (from llm-agents), with its remote-connection timeouts sized for
# Dave's laptop on hotel Wi-Fi / phone hotspot / 4G (300-600 ms RTT, loss)
# over yggdrasil. herdr has no config option for any of these (0.9.5), so
# they are patched; every patch is `--replace-fail`, so an upstream change
# breaks the build instead of silently dropping one.
#
# - NONINTERACTIVE_SSH_COMMAND_TIMEOUT 15 s -> 90 s: the saved-machine
#   reconnect starts with plain ssh commands (platform detection, status)
#   that also create herdr's ControlMaster. A fresh connection to a space
#   on such a link takes ~30 s (TPM signature, the ssh-tpm-agent confirm
#   dialog, a few round trips): killed at 15 s, the master never comes up
#   and the pane stays on "reconnecting" for good.
# - ConnectTimeout 10 s -> 30 s (same commands): TCP + banner over a mesh
#   that is still re-peering after a network switch.
# - HEARTBEAT_TIMEOUT 10 s -> 25 s: a ping answered late on a loaded,
#   bufferbloated 4G link is not a dead link; each false expiry tears down
#   every pane of that machine and replays the handshake.
# - ACTIVATION_TIMEOUT 5 s -> 15 s: the surface on/off acknowledgement of a
#   machine switch ("endpoint did not acknowledge surface revocation",
#   which then closes that transport too).
# - MAX_RETRY_DELAY 120 s -> 20 s: reconnect backoff cap. After a
#   flapping hour the next try was up to 2 min away; a retry is one mux
#   session over a live master, cheap.
#
# Dead links are still found fast: herdr passes ServerAliveInterval=15 /
# CountMax=4 on the command line of the ssh that becomes its ControlMaster
# (/tmp/hssh-<uid>/), so a dead master exits within ~1 min; health pings
# expire within ~30 s. No dispatcher kills masters on a network switch:
# the mesh address stays the same, so a master usually survives the switch,
# and a needless kill costs a ~30 s reconnect with a TPM signature.
#
# One package for every herdr here (Dave's desktops and the guests' herdr
# servers, ./herdr-jj.nix, ./noctalia-herdr-sound), so it is built once.
#
# Client-side constants only: protocol and capabilities are unchanged, so a
# patched client talks to an unpatched server (an older guest) and back.
{ pkgs, inputs }:
inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.herdr.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    substituteInPlace src/remote/attach.rs \
      --replace-fail 'const NONINTERACTIVE_SSH_COMMAND_TIMEOUT: Duration = Duration::from_secs(15);' \
                     'const NONINTERACTIVE_SSH_COMMAND_TIMEOUT: Duration = Duration::from_secs(90);' \
      --replace-fail '.arg("ConnectTimeout=10")' '.arg("ConnectTimeout=30")'
    substituteInPlace src/client/endpoint/health.rs \
      --replace-fail 'const HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(10);' \
                     'const HEARTBEAT_TIMEOUT: Duration = Duration::from_secs(25);'
    substituteInPlace src/client/endpoint/activation.rs \
      --replace-fail 'const ACTIVATION_TIMEOUT: Duration = Duration::from_secs(5);' \
                     'const ACTIVATION_TIMEOUT: Duration = Duration::from_secs(15);'
    substituteInPlace src/client/endpoint/supervisor.rs \
      --replace-fail 'const MAX_RETRY_DELAY: Duration = Duration::from_secs(120);' \
                     'const MAX_RETRY_DELAY: Duration = Duration::from_secs(20);'
  '';
})
