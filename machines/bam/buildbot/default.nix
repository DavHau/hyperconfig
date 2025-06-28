{
  inputs,
  pkgs,
  ...
}: {
  imports = [
    inputs.buildbot-nix.nixosModules.buildbot-master
    inputs.buildbot-nix.nixosModules.buildbot-worker
  ];

  services.buildbot-nix.master = {
    enable = true;
    # Domain name under which the buildbot frontend is reachable
    domain = "bam";
    # The workers file configures credentials for the buildbot workers to connect to the master.
    # "name" is the configured worker name in services.buildbot-nix.worker.name of a worker
    # (defaults to the hostname of the machine)
    # "pass" is the password for the worker configured in `services.buildbot-nix.worker.workerPasswordFile`
    # "cores" is the number of cpu cores the worker has.
    # The number must match as otherwise potentially not enought buildbot-workers are created.
    workersFile = pkgs.writeText "workers.json" ''
      [
        { "name": "bam", "pass": "hello", "cores": 16 }
      ]
    '';

    buildSystems = [
      "x86_64-linux"
    ];

    authBackend = "none";

    jobReportLimit = 0;
    # optional nix-eval-jobs settings
    evalWorkerCount = 16; # limit number of concurrent evaluations
    evalMaxMemorySize = 2048; # limit memory usage per evaluation

    pullBased.repositories.hyperconfig = {
      url = "https://github.com/DavHau/hyperconfig";
      pollInterval = 10;
      defaultBranch = "master";
    };
  };

  services.buildbot-nix.worker = {
    enable = true;
    # FIXME: replace this with a secret not stored in the nix store
    workerPasswordFile = pkgs.writeText "worker-password" "hello";
    workers = 16;
    name = "bam.dave";
  };

  networking.firewall.allowedTCPPorts = [80];
}
