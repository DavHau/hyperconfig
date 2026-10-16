/*
  A private /tmp and /var/tmp for every normal user (pam_namespace
  polyinstantiation). Every session of user X (ssh, console, su, X's
  systemd user manager) sees /tmp/.inst/X as /tmp and /var/tmp/.inst/X as
  /var/tmp; other users' files do not exist in that view. Root keeps the
  real directories and sees everything. /tmp/.inst and /var/tmp/.inst are
  mode 000 (pam_namespace refuses anything else), so processes outside a
  session cannot reach into the instances either.

  System services running as a user have no PAM session. To give one the
  same view, bind the instances into it:
    BindPaths = [ "/tmp/.inst/<user>:/tmp" "/var/tmp/.inst/<user>:/var/tmp" ];
  The instance dirs are pre-created for every normal user; without a "-"
  prefix a missing one stops the unit instead of leaving it on the shared
  dirs.

  mount_private: NixOS mounts are shared, so without it the per-session
  bind would propagate back into the host namespace.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hyper.perUserTmp;
  dirs = [
    "/tmp"
    "/var/tmp"
  ];
  normalUsers = lib.attrNames (lib.filterAttrs (_: u: u.isNormalUser) config.users.users);
  pam = config.security.pam.package;
  # nixpkgs builds PAM with its config dir in the store, so the stock
  # pam_namespace only ever reads the (all commented-out) namespace.conf
  # shipped there and silently does nothing. Same PAM, with only
  # pam_namespace's config paths pointed at /etc/security.
  pamNamespace = pam.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace modules/pam_namespace/pam_namespace.h \
        --replace-fail '(SCONFIG_DIR "/namespace' '("/etc/security/namespace'
    '';
  });
  # PAM services that open user sessions. login covers greetd (it includes
  # login).
  sessionServices = [
    "login"
    "sshd"
    "su"
    "systemd-user"
  ];

  sweep = pkgs.writeShellApplication {
    name = "per-user-tmp-sweep";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      config.systemd.package
    ];
    text = builtins.readFile ./sweep.sh;
  };
in
{
  options.hyper.perUserTmp.enable = lib.mkEnableOption "a private /tmp and /var/tmp per normal user";

  config = lib.mkIf cfg.enable {
    environment.etc."security/namespace.conf".text = lib.concatMapStrings (d: ''
      ${d} ${d}/.inst/ user root
    '') dirs;

    security.pam.services = lib.genAttrs sessionServices (
      svc:
      let
        unixOrder = config.security.pam.services.${svc}.rules.session.unix.order;
      in
      {
        rules.session = {
          # Root never enters pam_namespace, so a broken namespace setup
          # cannot lock root out too.
          namespace-skip-root = {
            order = unixOrder + 10;
            control = "[success=1 default=ignore]";
            modulePath = "${pam}/lib/security/pam_succeed_if.so";
            args = [
              "quiet"
              "uid"
              "="
              "0"
            ];
          };
          namespace = {
            order = unixOrder + 11;
            control = "required";
            modulePath = "${pamNamespace}/lib/security/pam_namespace.so";
            args = [ "mount_private" ];
          };
        };
      }
    );

    # Instances look exactly like pam_namespace makes them (the polydir's
    # mode and owner), so a pre-created one is taken as is.
    systemd.tmpfiles.rules = lib.concatMap (
      d: [ "d ${d}/.inst 0000 root root -" ] ++ map (u: "d ${d}/.inst/${u} 1777 root root -") normalUsers
    ) dirs;

    systemd.services.per-user-tmp-sweep = {
      description = "Move users' leftovers in shared /tmp and /var/tmp into their instances";
      wantedBy = [ "multi-user.target" ];
      after = [
        "local-fs.target"
        "systemd-tmpfiles-setup.service"
      ];
      before = [ "systemd-user-sessions.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe sweep} ${lib.escapeShellArgs normalUsers}";
      };
    };
  };
}
