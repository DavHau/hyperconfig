# The wallet on one host with two agents, alice (opted in) and bob (not).
#
# phoenixd opens its HTTP API only once it reaches an Electrum server and
# the ACINQ LSP (Phoenixd.kt waits for both before embeddedServer), which
# the test VM cannot. So: phoenixd starts with the seed and the password
# and stays up, retrying; then a stand-in API on its port (Basic auth, as
# phoenixd's) shows that alice's `lnwallet` authenticates with the
# password from apiConfigFile while bob cannot read it, so he never gets
# past the API's authentication. alice gets `lnwallet` on her agent's PATH
# and the lightning-wallet skill in her config.yaml, bob neither.
{ pkgs, self }:
let
  secrets = "/run/hh-secrets";
  password = "test-wallet-password";
  configOf = user: "${self.lib.stateDir user}/.hermes/config.yaml";

  # phoenixd's API as phoenix-cli sees it: 401 with a Basic challenge
  # unless the request carries the password, then a getinfo-shaped answer.
  fakeApi = pkgs.writers.writePython3 "fake-phoenixd-api" { } ''
    import base64
    from http.server import BaseHTTPRequestHandler, HTTPServer


    def password(auth):
        # phoenixd checks the password only, whatever the user name.
        if not auth.startswith("Basic "):
            return None
        return base64.b64decode(auth[6:]).decode().partition(":")[2]


    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            auth = self.headers.get("Authorization", "")
            if password(auth) == "${password}":
                body = b'{"nodeId": "fake-node"}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            else:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="phoenix"')
                self.send_header("Content-Length", "0")
                self.end_headers()


    HTTPServer(("127.0.0.1", 9740), Handler).serve_forever()
  '';
in
pkgs.testers.runNixOSTest {
  name = "hyperhermes-wallet";

  nodes.machine = {
    imports = [
      self.nixosModules.core
      self.nixosModules.wallet
    ];
    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;

    services.hyperhermes = {
      # The agents' pip venv without the default data-science set: the
      # test needs the unit, not torch.
      pythonPackages = _: [ ];
      agents.alice = {
        uid = 1001;
        wallet.enable = true;
      };
      agents.bob.uid = 1002;
      wallet = {
        enable = true;
        seedFile = "${secrets}/seed";
        apiConfigFile = "${secrets}/api/phoenix.conf";
      };
    };

    # The runtime secrets with the owners and modes nixosModules.clan's
    # generators give them. The seed is the BIP39 all-zero test vector.
    systemd.tmpfiles.rules = [
      "d ${secrets} 0755 root root - -"
      "d ${secrets}/api 0755 root root - -"
      "f ${secrets}/seed 0400 phoenixd phoenixd - abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
      "f ${secrets}/api/phoenix.conf 0440 phoenixd lightning-wallet - http-password=${password}"
    ];
  };

  testScript =
    { nodes, ... }:
    let
      lnwallet = pkgs.lib.findFirst (
        p: p.name == "lnwallet"
      ) (throw "alice has no lnwallet") nodes.machine.services.hyperhermes.agents.alice.extraPackages;
    in
    ''
      machine.wait_for_unit("phoenixd.service")
      for user in ("alice", "bob"):
          machine.wait_for_unit(f"hermes-agent-{user}.service")

      with subtest("phoenixd runs with the seed and the API password"):
          # Its own copy of the conf, which it appends its generated
          # secrets to on start.
          machine.wait_until_succeeds("grep -q '^http-password-limited-access=' /var/lib/phoenixd/phoenix.conf")
          machine.succeed("grep -qx 'http-password=${password}' /var/lib/phoenixd/phoenix.conf")
          assert machine.succeed("stat -c '%a %U' /var/lib/phoenixd").strip() == "700 phoenixd"
          # Offline it keeps retrying the Electrum server and the LSP
          # instead of failing.
          machine.succeed("sleep 15")
          machine.succeed("systemctl is-active phoenixd.service")
          assert machine.succeed("systemctl show -p NRestarts --value phoenixd.service").strip() == "0"

      with subtest("only the opted-in agent has the lnwallet CLI, the skill and the group"):
          env = machine.succeed("systemctl show -p Environment hermes-agent-alice.service")
          assert "${lnwallet}/bin" in env, env
          env = machine.succeed("systemctl show -p Environment hermes-agent-bob.service")
          assert "${lnwallet}/bin" not in env, env
          machine.succeed("grep -q 'agent-skill-lightning-wallet' ${configOf "alice"}")
          machine.fail("grep -q 'agent-skill-lightning-wallet' ${configOf "bob"}")
          machine.succeed("id -nG alice | grep -qw lightning-wallet")
          machine.fail("id -nG bob | grep -qw lightning-wallet")

      with subtest("alice's lnwallet authenticates, bob gets nowhere"):
          machine.succeed("systemctl stop phoenixd.service")
          machine.succeed("systemd-run --unit fake-phoenixd-api ${fakeApi}")
          machine.wait_for_open_port(9740)
          out = machine.succeed("runuser -u alice -- ${lnwallet}/bin/lnwallet getinfo")
          assert "fake-node" in out, out
          machine.fail("runuser -u bob -- cat ${secrets}/api/phoenix.conf")
          machine.fail("runuser -u bob -- cat ${secrets}/seed")
          machine.fail("runuser -u bob -- cat /var/lib/phoenixd/phoenix.conf")
          out = machine.execute("runuser -u bob -- ${lnwallet}/bin/lnwallet getinfo 2>&1")[1]
          assert "fake-node" not in out, out
    '';
}
