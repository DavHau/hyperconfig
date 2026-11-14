# sec-job-guard's evaluation check (./guard.sh): what a security job's
# push may never change on any machine, as JSON. guard.sh applies this
# to `nixosConfigurations` of main@origin and of the pushed commit
# (`nix eval --json <flake>#nixosConfigurations --apply`) and refuses
# ANY difference. It compares the evaluated configuration, not the
# diff's text, so the way an edit is written (nested attrsets,
# mkOverride, `!true`, a new module, a computed name) does not matter.
#
# Protected (policy rule 2, never lock Dave out): the network
# (firewall, nftables, hostId, interfaces, nameservers, DHCP, the
# gateway, systemd.network), sshd and resolved, users and PAM, boot
# (initrd, loader, kernel, its parameters and modules), file systems,
# nix's trust settings, and the protected units (sshd, the mesh,
# pocket-id, nginx, the infra-space container, DNS and networkd,
# alloy, acme, the display manager, user@, nix-daemon, borgbackup):
# their unit text, enable and wantedBy/requiredBy, plus which of them
# exist and systemd.suppressedSystemUnits. A takedown
# (../../security-takedown/) only turns off takedown-eligible units,
# which the eligibility assertion keeps out of this list, so it shows
# no difference here.
#
# Values JSON cannot hold: a derivation is its drvPath, a package set
# (boot.kernelPackages) its kernel's drvPath, a function "<function>",
# a value that throws "<error>"; users.users.*.packages is left out
# (movable flake inputs like afk change it without touching access).
# A whole configuration that fails to evaluate is "<eval-error>":
# guard.sh refuses that on the pushed side.
let
  protectedUnit =
    n:
    builtins.match (
      "(sshd|sshd@.*|sshd-.*|zerotierone|zerotier.*|wireguard.*|wg-.*|wg-quick-.*|tinc.*|hyprspace.*"
      + "|pocket-id.*|nginx|container@infra-space|dnscrypt.*|systemd-resolved|systemd-networkd.*"
      + "|alloy|acme-.*|display-manager|greetd|user@|user@.*|nix-daemon|borgbackup.*)"
      + "\\.(service|socket|timer|target|path)"
    ) n != null;

  # environment.etc entries that decide who gets in and how the network
  # resolves (systemd/system/<unit>.d/ drop-ins included; the generated
  # unit directory itself, `systemd/system`, is the units above)
  protectedEtc =
    k:
    builtins.match (
      "(systemd/system/.+|systemd/network.*|systemd/networkd.*|systemd/resolved.*|ssh/.*|ssh"
      + "|pam\\.d.*|pam/.*|security/.*|hosts|resolv\\.conf|nsswitch\\.conf|nftables.*|sudoers.*|doas.*"
      + "|nix/.*|passwd|group|shadow|login\\.defs|polkit-1/.*|static-nodes-permissions\\.conf)"
    ) k != null;
  lib = {
    filterAttrs = pred: set: builtins.removeAttrs set (builtins.filter (k: !pred k set.${k}) (builtins.attrNames set));
  };

  isDrv = v: builtins.isAttrs v && (v.type or null) == "derivation";
  try =
    v:
    let
      r = builtins.tryEval v;
    in
    if r.success then r.value else "<error>";

  norm =
    depth: v0:
    let
      r = builtins.tryEval v0;
      v = r.value;
    in
    if !r.success then
      "<error>"
    else if depth > 24 then
      "<too-deep>"
    else if builtins.isFunction v then
      "<function>"
    else if builtins.isPath v then
      str (toString v)
    else if isDrv v then
      { drv = try (builtins.unsafeDiscardStringContext v.drvPath); }
    else if builtins.isAttrs v && (v ? kernel) && (v ? callPackage) then
      { pkgset-kernel = try (builtins.unsafeDiscardStringContext v.kernel.drvPath); }
    else if builtins.isAttrs v && (v ? __toString) then
      try (toString v)
    else if builtins.isAttrs v then
      builtins.mapAttrs (_: norm (depth + 1)) v
    else if builtins.isList v then
      map (norm (depth + 1)) v
    else if builtins.isString v then
      str v
    else
      v;

  # A copied source tree (the repo itself, whose store path moves on every
  # edit; other flake inputs) is named by what is referenced in it: each
  # `<tree>/<sub path>` in a string becomes `<source:sha256 of that file
  # or directory>` (builtins.path: content-addressed, so the same file
  # gives the same name in base and head, a changed one a new name). A
  # bare tree reference (the whole repo) stays `<source>`.
  srcRe = "(/nix/store/[a-z0-9]{32}-source)(/[^][[:space:]'\";:,=()<>{}$`]*)?";
  ref =
    tree: sub:
    if sub == null || sub == "/" then
      "<source>"
    else
      let
        p = tree + sub;
        h = try (builtins.path {
          path = p;
          name = "ref";
        });
      in
      "<source${sub}:${if builtins.isString h then builtins.substring 11 32 h else "missing"}>";
  str =
    s:
    builtins.concatStringsSep "" (
      map (x: if builtins.isList x then ref (builtins.elemAt x 0) (builtins.elemAt x 1) else x) (
        builtins.split srcRe (builtins.unsafeDiscardStringContext s)
      )
    );
  n = norm 0;
  masked =
    v:
    if builtins.isString v then
      builtins.concatStringsSep "" (
        map (x: if builtins.isList x then "/nix/store/<hash>-" else x) (
          builtins.split "/nix/store/[a-z0-9]{32}-" v
        )
      )
    else
      v;

  # A subtree of options, walked option by option: an alias (a renamed
  # option, "Alias of ...") is skipped, its value is the target's,
  # which is protected wherever that lies in the list; reading it
  # could abort (a rename to a missing option) and abort is no
  # catchable error.
  isOpt = o: builtins.isAttrs o && (o._type or null) == "option";
  isAlias =
    o:
    let
      d = o.description or "";
    in
    builtins.isString d && builtins.match "Alias of .*" d != null;
  walk =
    o:
    if isOpt o then
      if isAlias o then
        "<alias>"
      else if !(try (o.isDefined or true)) then
        "<undefined>"
      else
        n o.value
    else if builtins.isAttrs o then
      builtins.mapAttrs (_: walk) (builtins.removeAttrs o [ "_module" ])
    else
      "<not-an-option>";
  at = path: o: builtins.foldl' (acc: k: acc.${k} or { }) o path;
  sub = o: path: walk (at path o);

  extract =
    m:
    let
      o = m.options;
      c = m.config;
      units = c.systemd.units;
      names = builtins.filter protectedUnit (builtins.attrNames units);
      eligible = c.security.takedown.eligible or [ ];
      unit = u: {
        text = n (units.${u}.text or null);
        enable = n (units.${u}.enable or null);
        wantedBy = n (units.${u}.wantedBy or null);
        requiredBy = n (units.${u}.requiredBy or null);
        upheldBy = n (units.${u}.upheldBy or null);
      };
    in
    {
      networking = builtins.listToAttrs (
        map (k: {
          name = k;
          value = sub o [
            "networking"
            k
          ];
        }) [
          "firewall"
          "nftables"
          "hostId"
          "interfaces"
          "nameservers"
          "useDHCP"
          "useNetworkd"
          "defaultGateway"
          "defaultGateway6"
        ]
      );
      systemd-network = sub o [ "systemd" "network" ];
      openssh = sub o [ "services" "openssh" ];
      resolved = sub o [ "services" "resolved" ];
      users = builtins.mapAttrs (_: u: n (builtins.removeAttrs u [ "packages" ])) c.users.users;
      mutableUsers = n c.users.mutableUsers;
      security-pam = sub o [ "security" "pam" ];
      boot = builtins.listToAttrs (
        map (k: {
          name = k;
          value = sub o [
            "boot"
            k
          ];
        }) [
          "loader"
          "kernelParams"
          "kernelPackages"
          "kernelModules"
          "blacklistedKernelModules"
        ]
      );
      # the initrd as built (walking its options can hit errors tryEval
      # does not catch, e.g. contents."/bin" without systemd in stage 1):
      # its drv holds the stage-1 network, ssh, luks and modules; the
      # secrets copied in at install time are the paths here
      initrd = {
        ramdisk = n (c.system.build.initialRamdisk.drvPath or null);
        secrets = n (c.boot.initrd.secrets or { });
        enable = n (c.boot.initrd.enable or null);
        systemd = n (c.boot.initrd.systemd.enable or null);
      };
      fileSystems = sub o [ "fileSystems" ];
      nix-settings = sub o [ "nix" "settings" ];
      nix-extraOptions = sub o [ "nix" "extraOptions" ];
      units = builtins.listToAttrs (
        map (u: {
          name = u;
          value = unit u;
        }) names
      );
      suppressedSystemUnits = n c.systemd.suppressedSystemUnits;
      # which units exist at all: a new unit runs whatever it likes at
      # boot (`nft flush ruleset` in a script). Takedown-eligible units
      # are left out, so a takedown (the jobs' one intended change)
      # shows no difference; the list itself is compared.
      unitNames = builtins.filter (u: !(builtins.elem u eligible)) (builtins.attrNames units);
      takedownEligible = n eligible;
      # an assertion that newly fails (e.g. a protected unit declared
      # eligible) is a broken build, refused before any deploy
      failedAssertions = map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
      tmpfiles = masked (builtins.toJSON (n {
        rules = c.systemd.tmpfiles.rules;
        settings = c.systemd.tmpfiles.settings;
      }));
      # beside the options: what reaches the same places another way
      # (a drop-in or a hosts/resolv.conf/PAM/sshd file through
      # environment.etc, sysctls, code run at every activation)
      etc = builtins.mapAttrs (_: e: {
        source = n (e.source or null);
        enable = n (e.enable or null);
        mode = n (e.mode or null);
      }) (lib.filterAttrs (k: _: protectedEtc k) c.environment.etc);
      sysctl = n c.boot.kernel.sysctl;
      # their text with store hashes masked (the etc tree and the
      # system path move with any package); `script` is all of them
      # joined
      activationScripts = builtins.mapAttrs (_: a: masked (n (a.text or a))) (
        builtins.removeAttrs c.system.activationScripts [ "script" ]
      );
    };
in
cs:
builtins.mapAttrs (
  _: m:
  let
    v = extract m;
    r = builtins.tryEval (builtins.deepSeq v v);
  in
  if r.success then r.value else "<eval-error>"
) cs
