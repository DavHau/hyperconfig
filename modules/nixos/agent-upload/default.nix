/*
  Uploads into a hermes agent's workspace from another fleet machine with
  plain rsync: Dave's laptop amy -> Wolfgang's agent on som, as data in
  ./targets.nix (agent -> from, to). Files land in the agent's
  /home/<agent>/hermes/workspace/uploads/<source dir name>/, where the
  agent finds them.

  Sending side (`from`):
    - the per-machine clan var agent-upload-<agent>-ssh: `key` (root
      only), `key.pub` (public, read by the receiving side from the repo);
    - the ssh alias `<agent>-upload` (/etc/ssh/ssh_config, before the
      desktops' `Host *` of ../ssh.nix so its values win): the receiving
      machine's yggdrasil address, its host key pinned from its public
      `openssh` var under that alias, the key above, no agent, no
      multiplexing (root's units run with a read-only home);
    - `upload-to-<agent>@<escaped dir>.service`, root: ./upload.py runs
      `rsync -rt --partial --append-verify -z --info=progress2 <dir>
      <agent>-upload:` (resumable: files done are skipped, a broken file
      keeps its received part and the next run sends only the rest, the
      whole file checksummed at the end) and writes a JSON
      status (state, files and bytes done/total, rate, ETA) to
      /var/lib/agent-upload/<agent>/<name>.json here and, every 15 s and at
      the end, on the receiving side. Restart=on-failure every 15 s without
      a start limit, so a roaming laptop's dropped link just resumes.
      Start: `systemctl start upload-to-<agent>@$(systemd-escape -p <dir>).service`.
      Not --partial-dir: rsync refuses it beside --append-verify, and
      under rrsync's pinned paths a partial dir's file is lost on a drop.

  Receiving side (`to`):
    - the key authorized for the agent's account as
      `restrict,from=<sender's yggdrasil address>,command=./dispatch.sh`
      (only from the sender's mesh address; no pty, no forwarding of any kind;
      the agent account never gets root): rrsync (rsync's restricted
      wrapper) write-only, without deletes, rooted in the uploads dir; or
      `agent-upload-status <name>`, which stores stdin as
      /var/lib/agent-upload/<agent>/<name>.json. Nothing else runs. The key
      is authorized only once its var is generated (null public value:
      skipped, no eval failure).
    - the uploads dir (agent's, 0755) and the status dir (agent:nginx
      2750, files 0640);
    - on the host with the infra-space dashboard (som), the progress page
      https://<dashboard host>/uploads/ (./page.html, refreshing every
      5 s) and its data under /uploads/status/ (nginx autoindex as JSON
      plus the status files, served as inert JSON, no symlinks followed),
      Dave only: the same auth subrequest to the dashboard's session as
      clan-secret-prompt's page (../infra-space/dashboard.nix), else a
      redirect to its sign-in.
*/
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  host = config.networking.hostName;
  targets = import ./targets.nix;
  flake = config.clan.core.settings.directory;
  publicValue =
    machine: generator: file:
    let
      v = inputs.clan-core.clanLib.getPublicValue {
        inherit
          flake
          machine
          generator
          file
          ;
        default = null;
      };
    in
    if v == null then null else lib.trim v;

  generatorOf = agent: "agent-upload-${agent}-ssh";
  aliasOf = agent: "${agent}-upload";
  stateRoot = "/var/lib/agent-upload";
  uploadsOf = agent: "${inputs.hyperhermes.lib.workspace agent}/uploads";

  sending = lib.filterAttrs (_: t: t.from == host) targets;
  receiving = lib.filterAttrs (
    agent: t: t.to == host && publicValue t.from (generatorOf agent) "key.pub" != null
  ) targets;
  receivingAll = lib.filterAttrs (_: t: t.to == host) targets;

  uploadPy = pkgs.writeText "agent-upload.py" (builtins.readFile ./upload.py);

  dispatchFor =
    agent:
    pkgs.writeShellScript "agent-upload-dispatch-${agent}" ''
      export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
      export RRSYNC=${pkgs.rrsync}/bin/rrsync
      export UPLOADS=${lib.escapeShellArg (uploadsOf agent)}
      export STATUS_DIR=${stateRoot}/${agent}
      exec ${pkgs.bash}/bin/bash ${./dispatch.sh}
    '';

  dashboardOn = lib.attrByPath [ "hyper" "infraSpace" "dashboard" "enable" ] false config;
  auth = ''
    auth_request /_infra_space_secret_auth;
    error_page 401 = @agent_upload_login;
    # (a location's add_header replaces the vhost's: its framing ones too)
    add_header Cache-Control "no-store" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
  '';

in
{
  config = lib.mkMerge [
    (lib.mkIf (sending != { }) {
      clan.core.vars.generators = lib.mapAttrs' (
        agent: _:
        lib.nameValuePair (generatorOf agent) {
          files.key.secret = true;
          files."key.pub".secret = false;
          runtimeInputs = [ pkgs.openssh ];
          script = ''
            ssh-keygen -q -t ed25519 -N "" -C "${agent}-upload@${host}" -f "$out"/key
          '';
        }
      ) sending;

      programs.ssh.knownHosts = lib.mapAttrs' (
        agent: t:
        lib.nameValuePair "agent-upload-${agent}" {
          hostNames = [ (aliasOf agent) ];
          publicKey = publicValue t.to "openssh" "ssh.id_ed25519.pub";
        }
      ) sending;

      programs.ssh.extraConfig = lib.mkBefore (
        lib.concatStrings (
          lib.mapAttrsToList (agent: t: ''
            Host ${aliasOf agent}
              HostName ${publicValue t.to "yggdrasil" "address"}
              User ${agent}
              HostKeyAlias ${aliasOf agent}
              StrictHostKeyChecking yes
              UserKnownHostsFile /dev/null
              IdentityFile ${config.clan.core.vars.generators.${generatorOf agent}.files.key.path}
              IdentitiesOnly yes
              IdentityAgent none
              BatchMode yes
              ControlMaster no
              ControlPath none
              Compression no
              ServerAliveInterval 30
              ServerAliveCountMax 4
              ConnectTimeout 30

          '') sending
        )
      );

      systemd.services = lib.mapAttrs' (
        agent: _:
        lib.nameValuePair "upload-to-${agent}@" {
          description = "Upload %f to ${agent}'s hermes workspace";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          path = [
            pkgs.rsync
            pkgs.openssh
          ];
          unitConfig.StartLimitIntervalSec = 0;
          serviceConfig = {
            Type = "exec";
            ExecStart = "${pkgs.python3}/bin/python3 ${uploadPy} ${aliasOf agent} ${stateRoot}/${agent} %f";
            Restart = "on-failure";
            RestartSec = 15;
            StateDirectory = "agent-upload/${agent}";
            Nice = 10;
            IOSchedulingClass = "idle";
            ProtectSystem = "strict";
            ProtectHome = "read-only";
            PrivateTmp = true;
            NoNewPrivileges = true;
            # root only to read Dave's files and its own key and state:
            # nothing else if rsync or ssh ever mishandle the far end
            CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
            PrivateDevices = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            RestrictAddressFamilies = [
              "AF_UNIX"
              "AF_INET"
              "AF_INET6"
            ];
            RestrictNamespaces = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
          };
        }
      ) sending;
    })

    (lib.mkIf (receivingAll != { }) {
      users.users = lib.mapAttrs (agent: t: {
        openssh.authorizedKeys.keys = lib.optional (receiving ? ${agent}) ''restrict,from="${publicValue t.from "yggdrasil" "address"}",command="${dispatchFor agent}" ${publicValue t.from (generatorOf agent) "key.pub"}'';
      }) receivingAll;

      systemd.tmpfiles.rules = [
        "d ${stateRoot} 0755 root root - -"
      ]
      ++ lib.concatLists (
        lib.mapAttrsToList (agent: _: [
          "d ${uploadsOf agent} 0755 ${agent} users - -"
          "d ${stateRoot}/${agent} 2750 ${agent} ${config.services.nginx.group} - -"
        ]) receivingAll
      );
    })

    (lib.mkIf (receivingAll != { } && dashboardOn) {
      services.nginx.virtualHosts.infra-space-dashboard.locations = {
        "= /uploads".extraConfig = "return 301 /uploads/;";
        "= /uploads/" = {
          root = "/";
          tryFiles = "${./page.html} =404";
          extraConfig = auth + ''
            add_header Content-Security-Policy "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'" always;
            default_type text/html;
          '';
        };
        # ^~: no regex location of the vhost takes these over
        "^~ /uploads/status/" = {
          alias = "${stateRoot}/";
          extraConfig = auth + ''
            # the agent owns its status dir: never follow a link it plants,
            # and whatever it drops there is inert JSON on this origin
            # (an x.html there must not run in Dave's dashboard session)
            disable_symlinks on;
            types { }
            default_type application/json;
            add_header Content-Security-Policy "default-src 'none'; sandbox" always;
            autoindex on;
            autoindex_format json;
          '';
        };
        "@agent_upload_login".extraConfig = ''
          return 302 /login?next=/uploads/;
        '';
      };
    })
  ];
}
