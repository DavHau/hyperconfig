# nixosModules.android-apps on its own, with stand-in APKs (the real
# builds take minutes and need the network-free gradle lock; the module
# only signs and serves whatever it is given): the signing unit signs with
# the keystore at runtime paths, apksigner verifies the result with the
# keystore's certificate, nginx serves /apps/ without the host's sign-in
# (auth_request answers 401 everywhere else), and an APK the module no
# longer lists is gone after the next sign.
# (A container test: no VM needed.)
{ pkgs, self }:
let
  # The smallest APK apksigner accepts: a zip with a manifest entry.
  fakeApk =
    name:
    pkgs.runCommand "${name}-unsigned" {
      nativeBuildInputs = [ pkgs.zip ];
      passthru.apk = "${name}-unsigned.apk";
      pname = name;
      version = "1.0";
    } ''
      mkdir -p $out x
      printf 'not really a manifest' > x/AndroidManifest.xml
      (cd x && zip -q -0 -X $out/${name}-unsigned.apk AndroidManifest.xml)
    '';
  appA = (fakeApk "app-a") // {
    pname = "app-a";
    version = "1.0";
  };
  appB = (fakeApk "app-b") // {
    pname = "app-b";
    version = "2.0";
  };
in
pkgs.testers.runNixOSTest {
  name = "hyperhermes-android-apps";

  containers.machine =
    { lib, ... }:
    {
      imports = [ self.nixosModules.android-apps ];
      services.hyperhermes.androidApps = {
        enable = true;
        host = "apps.test";
        apps = { inherit appA appB; };
        keystoreFile = "/run/test-secrets/keystore.p12";
        passwordFile = "/run/test-secrets/password";
      };
      # The front door's shape: everything else behind auth_request.
      services.nginx = {
        enable = true;
        virtualHosts."apps.test" = {
          default = true;
          extraConfig = ''
            auth_request /deny;
          '';
          locations."= /deny".return = "401";
          # Static content: a `return` would answer before auth_request.
          locations."/".root = pkgs.writeTextDir "index.html" "private";
        };
      };
      # Not wanted at boot: the test places the keystore first.
      systemd.services.android-apps-sign.wantedBy = lib.mkForce [ ];
      environment.systemPackages = [
        pkgs.apksigner
        pkgs.curl
      ];
    };

  testScript = ''
    machine.wait_for_unit("nginx.service")
    machine.succeed(
      "install -d -m 0700 /run/test-secrets",
      "printf 'test-store-pass' > /run/test-secrets/password",
      "${pkgs.jdk21_headless}/bin/keytool -genkeypair -noprompt -storetype PKCS12"
      " -keystore /run/test-secrets/keystore.p12 -alias hermes -keyalg RSA -keysize 2048"
      " -validity 10 -dname CN=test -storepass test-store-pass -keypass test-store-pass",
    )

    with subtest("the unit signs both apps with the keystore's key"):
        machine.succeed("systemctl start android-apps-sign.service")
        machine.succeed("ls -l /var/lib/android-apps >&2")
        for f in ["app-a-1.0.apk", "app-b-2.0.apk"]:
            certs = machine.succeed(f"apksigner verify --min-sdk-version 26 --print-certs /var/lib/android-apps/{f}")
            assert "CN=test" in certs, certs
        machine.fail("ls /var/lib/android-apps/*.idsig")
        # The key never reached the store or the served directory.
        machine.fail("grep -rl test-store-pass /var/lib/android-apps")

    with subtest("nginx serves /apps/ without sign-in, the rest still asks"):
        code = machine.succeed(
            "curl -s -o /tmp/a.apk -w '%{http_code} %{content_type}' http://127.0.0.1/apps/app-a-1.0.apk"
        )
        assert code == "200 application/vnd.android.package-archive", code
        machine.succeed("cmp /tmp/a.apk /var/lib/android-apps/app-a-1.0.apk")
        index = machine.succeed("curl -sf http://127.0.0.1/apps/")
        assert 'href="app-a-1.0.apk"' in index and 'href="app-b-2.0.apk"' in index, index
        assert machine.succeed("curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/") == "401"
        assert machine.succeed("curl -s --path-as-is -o /dev/null -w '%{http_code}' http://127.0.0.1/apps/../index.html") == "401"

    with subtest("a re-sign replaces the served set: an APK no longer listed goes"):
        machine.succeed("touch /var/lib/android-apps/old-0.9.apk")
        machine.succeed("systemctl restart android-apps-sign.service")
        machine.succeed("test -f /var/lib/android-apps/app-a-1.0.apk")
        machine.fail("test -e /var/lib/android-apps/old-0.9.apk")
  '';
}
