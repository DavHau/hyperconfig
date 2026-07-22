# Contract of the remote-building service, e2e:
#   1. toggle ON at boot: machines file lists the builder
#   2. stop/start round-trip empties/restores it
#   3. root@client authenticates as nixremote@builder with the deployed var key
#   4. a dependent build offloads: client-BUILT (signed) input is accepted
#      by the builder WITHOUT trusted-users, output is copied back
#   5. nixremote is not a trusted user on the builder (config assertion;
#      an unsigned-push probe is impossible from the client because
#      secret-key-files signs every local registration)
#
# Host keys: prod trusts them via the clan-core sshd CA; that service is
# out of scope here, so the test seeds known_hosts with ssh-keyscan.
{ ... }:
{
  name = "remote-building";

  clan = {
    directory = ./.;
    test.useContainers = true;
    inventory = {
      machines.builder1 = { };
      machines.client1 = { };

      instances = {
        remote-building = {
          module.name = "remote-building";
          module.input = "self";
          # Test network resolves bare hostnames, not <name>.d
          roles.builder.machines.builder1.settings.host = "builder1";
          roles.client.machines.client1 = { };
        };
      };
    };
  };

  nodes = {
    builder1 = {
      # Nested builds inside the test node cannot sandbox.
      nix.settings.sandbox = false;
      nix.settings.experimental-features = [ "nix-command" ];
    };
    client1 = {
      nix.settings.sandbox = false;
      nix.settings.experimental-features = [ "nix-command" ];
    };
  };

  testScript = ''
    start_all()

    # multi-user first: right after container boot the sshd start job may
    # not be queued yet, and wait_for_unit errors on inactive-with-no-jobs.
    # nixpkgs-unstable socket-activates sshd: the unit is sshd.socket, and
    # sshd@ instances are spawned per connection.
    builder1.wait_for_unit("multi-user.target")
    builder1.wait_for_unit("sshd.socket")
    client1.wait_for_unit("multi-user.target")

    # 1. ON at boot
    client1.wait_for_unit("remote-builders.service")
    machines_file = client1.succeed("cat /run/remote-builders/machines")
    assert "ssh-ng://nixremote@builder1" in machines_file, machines_file

    # 2. toggle round-trip
    client1.succeed("systemctl stop remote-builders.service")
    assert client1.succeed("cat /run/remote-builders/machines").strip() == ""
    client1.succeed("systemctl start remote-builders.service")
    assert "ssh-ng://nixremote@builder1" in client1.succeed("cat /run/remote-builders/machines")

    # host keys: prod uses the sshd CA; the test seeds known_hosts instead
    client1.succeed("mkdir -p /root/.ssh && ssh-keyscan builder1 >> /root/.ssh/known_hosts")

    # 3. ssh auth purely from deployed vars
    ssh_key = client1.succeed("awk '{print $3}' /etc/nix/machines").strip()
    client1.succeed(f"ssh -o BatchMode=yes -i {ssh_key} nixremote@builder1 true")

    # 4. e2e: dep built LOCALLY first (signed on registration by
    # secret-key-files), then top forced remote — the builder must accept
    # the client-signed dep path without trusted-users, build top, and the
    # daemon copies the output back.
    dep_expr = """derivation {
        name = "remote-building-dep";
        system = "x86_64-linux";
        builder = "/bin/sh";
        args = [ "-c" "echo dep > $out" ];
      }"""
    top_expr = f"""let dep = {dep_expr}; in derivation {{
        name = "remote-building-top";
        system = "x86_64-linux";
        builder = "/bin/sh";
        args = [ "-c" "cat $dep > $out; echo top >> $out" ];
        inherit dep;
      }}"""
    # dep: local only (empty --builders overrides the machines file)
    client1.succeed(f"nix build --builders ''' --expr '{dep_expr}' --out-link /tmp/dep")
    dep_path = client1.succeed("readlink -f /tmp/dep").strip()
    # proof the signing chain is live before involving the builder
    sigs = client1.succeed(f"nix path-info --sigs {dep_path}")
    assert "client1-remote-building-remote-building-1:" in sigs, sigs
    # top: remote only
    client1.succeed(f"nix build -L --max-jobs 0 --expr '{top_expr}' --out-link /tmp/result 2>&1")
    top_path = client1.succeed("readlink -f /tmp/result").strip()
    # output present on BOTH: built remotely, copied back
    builder1.succeed(f"test -e {top_path}")
    assert client1.succeed(f"cat {top_path}").strip().endswith("top")

    # 5. untrusted: no trusted-users grant anywhere for nixremote
    builder1.fail("grep -R nixremote /etc/nix/nix.conf | grep trusted-users")
  '';
}
