{
  # CHANGE ME: ensure this is unique among all clans you want to use.
  meta.name = "my-clan";
  # CHANGE ME: machines are reachable as <hostname>.<domain>
  # (via yggdrasil /etc/hosts entries). Lowercase DNS labels only.
  meta.domain = "my-clan.internal";

  # Store secrets (vars) with the age backend instead of sops.
  # Machine keys are auto-generated; each machine's private key is encrypted
  # to the admin recipients below. Your admin identity is picked up from
  # $AGE_KEY / $AGE_KEYFILE / ~/.config/age/identities (plugin identity files
  # for hardware tokens work too).
  # Docs: https://clan.lol/docs/guides/vars/age/age-backend
  vars.settings.secretStore = "age";

  # CHANGE ME: your admin age public key(s).
  #   YubiKey:      age-plugin-yubikey --generate   -> "age1yubikey1..."
  #   software key: age-keygen -o ~/.config/age/identities -> "age1..."
  vars.settings.recipients.default = [
    "age1REPLACE_WITH_YOUR_ADMIN_PUBLIC_KEY"
  ];

  # age plugins the clan CLI needs when encrypting/decrypting.
  secrets.age.plugins = [ "age-plugin-yubikey" ];

  inventory.machines = {
    # Rename this and add more machines here.
    # machines/<name>/configuration.nix is imported automatically.
    machine-one = { };
  };

  inventory.instances = {

    # Docs: https://clan.lol/docs/services/official/sshd
    # Persistent host keys and admin access; required for deployment.
    sshd = {
      roles.server.tags.all = { };
      roles.server.settings.authorizedKeys = {
        # Insert the public key(s) that get root SSH access to all machines.
        "admin" = "PASTE_YOUR_KEY_HERE";
      };
    };

    # Docs: https://clan.lol/docs/services/official/users
    # One generated root password, shared across all machines
    # (stored as a shared var; show it with: clan vars get <machine> user-root/user-password).
    user-root = {
      module.name = "users";
      roles.default.tags.all = { };
      roles.default.settings = {
        user = "root";
        prompt = false;
        share = true;
      };
    };

    # Docs: https://clan.lol/docs/services/official/zerotier
    # Private L2/L3 VPN. Exactly one machine must be the controller;
    # it admits new peers and should be mostly online.
    zerotier = {
      roles.controller.machines.machine-one = { };
      roles.peer.tags.all = { };
    };

    # Docs: https://clan.lol/docs/services/official/yggdrasil
    # Controller-less encrypted IPv6 overlay across ALL other connections:
    # automatically peers over every exported network (zerotier, internet, ...)
    # and discovers local peers via multicast, then picks the best route.
    # Gives each machine a stable address at <hostname>.<meta.domain>.
    yggdrasil = {
      roles.default.tags.all = { };
    };

    # Docs: https://clan.lol/docs/services/official/p2p-ssh-iroh
    # Status experimental.
    # NAT-traversing SSH via encrypted QUIC streams (iroh/dumbpipe).
    # Fallback when all VPNs are down, and lets you deploy from a
    # machine that is not (yet) part of the clan.
    p2p-ssh-iroh = {
      roles.server.tags.all = { };
    };
  };

  # Additional NixOS configuration can be added here.
  # See: https://clan.lol/docs/guides/inventory/autoincludes
  machines = {
    # machine-one = { config, pkgs, ... }: {
    #   environment.systemPackages = [ pkgs.htop ];
    # };
  };
}
