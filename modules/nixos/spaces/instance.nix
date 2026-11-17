/*
  One space-like container on this host, everything infra-space
  (../infra-space) and the named spaces (./default.nix) share: a function
  from the instance's parameters to the host configuration for it. The
  two kinds pass their parameters and keep only their own specifics
  (infra-space: fleet identities, hermes, dashboard, bump; the named
  spaces: registry, confinement, publishing, forges).

  What every instance gets:
    - the host side (./host.nix): container, veth (v4 10.235.0.<4i+1|2>,
      v6 fd23:5ace:0:<i>::1|2, index 0 infra-space's fd23:5ace::1|2), NAT,
      DNS, the sshd forward [address]:sshPort through a socket proxy as
      proxyUid, the output gate (root, the proxy, `toGuestRules`), the
      home at stateDir/home, TPM, own user namespace, credentials;
      `confine` with `siblingForwards` for the named spaces;
    - the guest's ssh host key as clan var `hostKeyGenerator` (passed in
      as credential `ssh-host-key`, sshd's only) and the p0, TeamClaude and
      OpenRouter keys as credentials for afk (shared vars, the desktops'
      too); every credential's rotation restarts the container (nspawn
      copies them in at start only);
    - the guest's base (./guest-base.nix: user, credentials at
      /run/<name>/secrets, sshd, inbound rule), afk (./afk.nix) and herdr's
      server (../herdr-jj.nix, for Dave's herdr machines, ./client.nix),
      the kind's own guest module (`guest`) and `guestModules` on top;
    - `siblings`: the same space's copies on other machines ({ machine,
      address, sshPort, hostKey, user }), reached from the guest as ssh
      alias <name>-<machine> with `siblingIdentity` (a credential), their
      host keys pinned; for a confined guest also let through to their
      forwards (./host.nix siblingForwards). Dave's desktops reach the
      same copies as <name>-<machine> too (./client.nix).
*/
{
  config,
  lib,
  pkgs,
  inputs,
}:
let
  vars = config.clan.core.vars.generators;
  spaceHost = import ./host.nix { inherit config lib pkgs; };
  hostKeyCredential = "ssh-host-key";
in
{
  name,
  user,
  uid,
  proxyUid,
  proxyUser,
  index,
  stateDir,
  guestHome,
  description,
  address,
  sshPort,
  meshInterface,
  tpm,
  privateUsers,
  credentials,
  hostKeyGenerator,
  authorizedKeys,
  # the kind's guest module (./guest.nix, ../infra-space/guest.nix), then
  # more of them
  guest,
  guestModules ? [ ],
  # more of the guest's `space` options (./guest-base.nix, ./guest.nix)
  guestSpace ? { },
  toGuestRules ? "",
  confine ? false,
  blockedDestinations ? {
    v4 = [ ];
    v6 = [ ];
  },
  siblings ? [ ],
  siblingIdentity ? null,
  immutableHelper ? null,
}:
let
  containerUnit = "container@${name}.service";
  secretsDir = "/run/${name}/secrets";
  v4 = n: "10.235.0.${toString (4 * index + n)}";
  # index 0 (infra-space) keeps its address as written since its start
  v6 =
    n: if index == 0 then "fd23:5ace::${toString n}" else "fd23:5ace:0:${toString index}::${toString n}";
  siblingAlias = s: "${name}-${s.machine}";
  allCredentials = credentials // {
    p0-api-key = vars.inference-api-key.files.token.path;
    teamclaude-api-key = vars.teamclaude-api-key.files.key.path;
    openrouter-api-key = vars.openrouter.files.apikey.path;
  };
in
lib.mkMerge [
  {
    assertions = [
      {
        assertion = !(credentials ? ${hostKeyCredential});
        message = "${name}: credential `${hostKeyCredential}` is the guest's ssh host key";
      }
      {
        assertion = siblings == [ ] || siblingIdentity != null;
        message = "${name}: siblings need a siblingIdentity credential";
      }
    ];

    clan.core.vars.generators = {
      inference-api-key.files.token.restartUnits = [ containerUnit ];
      teamclaude-api-key.files.key.restartUnits = [ containerUnit ];
      openrouter.files.apikey.restartUnits = [ containerUnit ];
      ${hostKeyGenerator} = {
        files.ssh_host_ed25519_key.restartUnits = [ containerUnit ];
        files."ssh_host_ed25519_key.pub".secret = false;
        runtimeInputs = [ pkgs.openssh ];
        script = ''
          ssh-keygen -q -t ed25519 -N "" -C "" -f "$out"/ssh_host_ed25519_key
        '';
      };
    };
  }
  (spaceHost {
    inherit
      name
      uid
      proxyUser
      proxyUid
      stateDir
      guestHome
      address
      sshPort
      meshInterface
      tpm
      privateUsers
      immutableHelper
      toGuestRules
      confine
      blockedDestinations
      ;
    hostAddress = v4 1;
    localAddress = v4 2;
    hostAddress6 = v6 1;
    localAddress6 = v6 2;
    homeDir = "${stateDir}/home";
    credentials = allCredentials // {
      ${hostKeyCredential} = vars.${hostKeyGenerator}.files.ssh_host_ed25519_key.path;
    };
    siblingForwards = lib.optionals confine (
      map (s: {
        inherit (s) address;
        port = s.sshPort;
      }) siblings
    );
    specialArgs = { inherit inputs; };
    guestConfig = {
      imports = [
        guest
        ./guest-base.nix
        ../herdr-jj.nix
        (import ./afk.nix secretsDir)
        {
          # before a guest's own `Host *` (./geninf-space.nix)
          programs.ssh.extraConfig = lib.mkBefore (
            lib.concatMapStrings (s: ''
              Host ${siblingAlias s}
                HostName ${s.address}
                Port ${toString s.sshPort}
                User ${s.user}
                IdentityFile ${secretsDir}/${siblingIdentity}
                IdentitiesOnly yes

            '') siblings
          );
          programs.ssh.knownHosts = lib.listToAttrs (
            map (
              s:
              lib.nameValuePair (siblingAlias s) {
                hostNames = [ "[${s.address}]:${toString s.sshPort}" ];
                publicKey = s.hostKey;
              }
            ) siblings
          );
        }
      ]
      ++ guestModules;
      space = {
        inherit
          name
          user
          uid
          description
          authorizedKeys
          hostKeyCredential
          tpm
          ;
        home = guestHome;
        credentials = lib.attrNames allCredentials;
        resolver = v4 1;
        hostAddress = v4 1;
        hostAddress6 = v6 1;
      }
      // guestSpace;
    };
  })
]
