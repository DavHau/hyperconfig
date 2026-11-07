# The systemd settings services.hyperhermes.hardening adds to every
# agent's gateway and dashboard units and its account's user manager
# (./options.nix, ./agents.nix).
# Plain data: the checks run transient units with exactly this set.
{
  RestrictNamespaces = true;
  # @system-service allows io_uring (its @aio group, systemd 262); the ~
  # entry takes it back out. The host's kernel.io_uring_disabled is the
  # main control; this covers a host without it.
  SystemCallFilter = [
    "@system-service"
    "~io_uring_setup io_uring_enter io_uring_register"
  ];
  # A filtered syscall fails with EPERM instead of killing the process
  # (systemd's default, SIGSYS). libuv (node) calls io_uring_setup and
  # falls back on an error; a SIGSYS would kill every node tool.
  SystemCallErrorNumber = "EPERM";
  NoNewPrivileges = true;
  RestrictSUIDSGID = true;
  LockPersonality = true;
  ProtectKernelModules = true;
  ProtectKernelTunables = true;
  ProtectKernelLogs = true;
  ProtectClock = true;
}
