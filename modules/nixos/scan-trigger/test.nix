# scan-trigger (./default.nix) and the driverless queue (../lan-printer.nix)
# against a fake MF272dw: `printer` serves eSCL (./fake_escl.py, a page with
# German, English and Thai text) and IPP (ippeveprinter) at 192.168.18.20 on
# an isolated net. `server` (bam's role) has the LAN alias 192.168.8.250 and
# a vault mount that comes up late; `desktop` is a LAN client with the
# print module; `printer` doubles as the non-LAN client.
#
# Checks: two pages + finish -> one searchable 2-page PDF (deu/eng/tha text
# found) in /vault/misc/scans/<year>/, owned by dave, 0600 without ACLs,
# delivered only once the mount appears; scan+finish; a 600 dpi colour page
# OCRs within the worker's MemoryMax (production ocrArgs); the POST a
# browser sends to a plain-http LAN page (real Origin, no Sec-Fetch-*)
# accepted, cross-site / foreign or null Origin / foreign Host / missing
# token / non-LAN peer refused; a sleeping printer gives a clear error; an
# endless eSCL body is cut off; page limit and full outbox refuse to scan;
# parallel clicks add one page; leftover pages after a crash are shown and
# can be discarded; the delivery survives hostile outbox entries (FIFO,
# non-PDF, oversized, re-delivered name) and the scan user can't lock it
# out; a recursive vault setfacl is undone; stale .part copies are swept;
# no delivery while it would leave outputDir below minFreeBytes or exceed
# the daily budget (the scan waits, the page says so); a worker that
# refuses early has its error shown; the OCR worker's sandbox reaches no
# host socket and no /vault (./ocr_probe.py), scan-trigger no /vault.
# Printing: no queue and no
# failed unit while the printer is off, queue with A4 + long-edge duplex
# once it is on.
{ pkgs }:
let
  inherit (pkgs) lib;
  fakePy = pkgs.python3.withPackages (ps: [ ps.pillow ]);
  latinFont = "${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf";
  thaiFont = "${pkgs.tlwg}/share/fonts/opentype/thai/Garuda.otf";
in
pkgs.testers.runNixOSTest {
  name = "scan-trigger";

  nodes = {
    printer = {
      virtualisation.vlans = [ 2 ];
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
        {
          address = "192.168.18.20";
          prefixLength = 24;
        }
      ];
      networking.firewall.enable = false;
      # Also the test's non-LAN client: reaches the LAN address via server.
      networking.interfaces.eth1.ipv4.routes = [
        {
          address = "192.168.8.0";
          prefixLength = 24;
          via = "192.168.18.1";
        }
      ];
      environment.systemPackages = [ pkgs.curl ];
      systemd.services.fake-escl = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${fakePy.interpreter} ${./fake_escl.py} 80 ${latinFont} ${thaiFont}";
          WorkingDirectory = "/var/lib/fake-escl";
          StateDirectory = "fake-escl";
        };
      };
      # Not started at boot: the printer is "off" for the first print check.
      systemd.services.fake-ipp = {
        serviceConfig.ExecStart = "${pkgs.cups}/bin/ippeveprinter -2 -M Canon -p 631 -r off -f application/pdf,image/pwg-raster,image/urf,image/jpeg -m 'MF270 Series' -d /tmp 'Canon MF272dw'";
      };
    };

    server =
      { config, ... }:
      {
        imports = [ ./default.nix ];
        virtualisation.vlans = [
          1
          2
        ];
        virtualisation.memorySize = 3072;
        networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
          {
            address = "192.168.8.250";
            prefixLength = 24;
          }
        ];
        networking.interfaces.eth2.ipv4.addresses = lib.mkForce [
          {
            address = "192.168.18.1";
            prefixLength = 24;
          }
        ];
        boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
        users.groups.vault.gid = 1101;
        users.users.dave = {
          isNormalUser = true;
          uid = 1000;
          extraGroups = [ "vault" ];
        };
        environment.systemPackages = [
          pkgs.poppler-utils
          pkgs.acl
        ];
        hyper.scanTrigger = {
          enable = true;
          printerAddress = "192.168.18.20";
          listenAddress = "192.168.8.250";
          allowedNetworks = [ "192.168.8.0/24" ];
          owner = "dave";
          outputDir = "/vault/misc/scans";
          requireMount = "/vault/misc";
          maxPages = 3;
          # The VM's disk is small.
          minFreeBytes = 64 * 1024 * 1024;
          maxDocBytes = 64 * 1024 * 1024;
        };
        systemd.tmpfiles.rules = [ "d /vault/misc 0755 root root -" ];
        # scan-ocr@'s exact sandbox, running a probe instead of the OCR.
        systemd.services.ocr-probe.serviceConfig = config.systemd.services."scan-ocr@".serviceConfig // {
          Type = "oneshot";
          ExecStart = "${pkgs.python3.interpreter} ${./ocr_probe.py}";
          StandardInput = "null";
          StandardOutput = "journal";
        };
      };

    desktop =
      { ... }:
      {
        imports = [ ../printer-canon-mf272dw.nix ];
        virtualisation.vlans = [
          1
          2
        ];
        networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
          {
            address = "192.168.8.10";
            prefixLength = 24;
          }
        ];
        networking.interfaces.eth2.ipv4.addresses = lib.mkForce [
          {
            address = "192.168.18.30";
            prefixLength = 24;
          }
        ];
        environment.systemPackages = [ pkgs.curl ];
      };
  };

  testScript = ''
    import re, time

    URL = "http://192.168.8.250:8088"
    # What Firefox/Chromium send for the page's own form post: plain http
    # to a private IP gets no Sec-Fetch-* headers, and the page's
    # same-origin Referrer-Policy keeps the real Origin.
    BROWSER = f"-H 'Origin: {URL}' -H 'User-Agent: Mozilla/5.0' -H 'Content-Type: application/x-www-form-urlencoded'"
    # A browser that does send Fetch metadata, with an opaque origin.
    FETCHMETA = "-H 'Sec-Fetch-Site: same-origin' -H 'Origin: null'"

    def grab(pattern, text):
        m = re.search(pattern, text)
        assert m is not None, f"{pattern!r} not in page: {text}"
        return m.group(1)

    def page(node=None):
        return (node or desktop).succeed(f"curl -sf {URL}/")

    def token():
        return grab(r'name="token" value="([^"]+)"', page())

    def post(action, extra=BROWSER, data=None, node=None):
        d = data if data is not None else f"token={token()}&do={action}&dpi=300&mode=color"
        return (node or desktop).succeed(
            f"curl -s -o /dev/null -w '%{{http_code}}' {extra} --data '{d}' {URL}/action"
        )

    def idle():
        with desktop.nested("wait until idle"):
            for _ in range(900):
                p = page()
                if "&hellip;" not in p:
                    return p
                time.sleep(1)
            raise Exception("scan-trigger stayed busy")

    def npages():
        return int(grab(r"Current document: <b>(\d+)</b>", page()))

    def err(p):
        assert "msg err" in p, p
        return grab(r'<div class="msg err">([^<]*)</div>', p)

    start_all()
    printer.wait_for_unit("fake-escl.service")
    server.wait_for_unit("scan-trigger.service")
    server.wait_for_unit("scan-deliver.service")
    server.wait_for_open_port(8088, "192.168.8.250")
    desktop.wait_for_unit("multi-user.target")

    with subtest("printing: printer off -> no queue, nothing failed"):
        # cups is socket-activated; the oneshot's Requires= starts it.
        desktop.wait_for_unit("cups.socket")
        desktop.systemctl("start lan-printer-canon.service")
        desktop.fail("systemctl is-failed lan-printer-canon.service")
        desktop.fail("lpstat -p canon")
        desktop.succeed("journalctl -u lan-printer-canon.service | grep -q 'not reachable'")

    with subtest("printing: printer on -> driverless queue, A4, long-edge duplex"):
        printer.systemctl("start fake-ipp.service")
        printer.wait_for_open_port(631)
        desktop.systemctl("start lan-printer-canon.service")
        desktop.succeed("lpstat -p canon")
        desktop.succeed("lpstat -v canon | grep -q 'ipp://192.168.18.20/ipp/print'")
        desktop.succeed("lpstat -d | grep -q canon")
        opts = desktop.succeed("lpoptions -p canon -l; lpoptions -p canon")
        print(opts)
        assert re.search(r"PageSize/[^:]*:.*\*A4\b", opts), "A4 not default"
        assert "sides=two-sided-long-edge" in opts or re.search(r"Duplex/[^:]*:.*\*DuplexNoTumble", opts), "duplex not default"
        desktop.succeed("echo hello | lp -d canon")

    with subtest("web: LAN only, same-origin only"):
        # Non-LAN peer (the IoT net), routed in through the server: dropped.
        printer.fail(f"curl -s --max-time 5 {URL}/")
        printer.fail("curl -s --max-time 5 http://192.168.18.1:8088/")
        p = page()
        assert "Scan page" in p and "color-scheme" in p
        t = token()
        assert post("scan", "-H 'Sec-Fetch-Site: cross-site'", f"token={t}&do=scan") == "403"
        assert post("scan", "-H 'Origin: http://evil.example'", f"token={t}&do=scan") == "403"
        assert post("scan", "-H 'Origin: null'", f"token={t}&do=scan") == "403"
        assert post("scan", "-H 'Origin: http://192.168.8.250:8088.evil.example'", f"token={t}&do=scan") == "403"
        assert post("scan", f"{BROWSER} -H 'Host: evil.example'", f"token={t}&do=scan") == "421"
        desktop.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' -H 'Host: evil.example' {URL}/ | grep -q 421")
        assert post("scan", BROWSER, "token=wrong&do=scan") == "303"
        idle()
        assert npages() == 0, "a refused POST scanned"
        assert "out of date" in page()
        # Fetch-metadata browser with Origin null: accepted.
        assert post("scan", FETCHMETA) == "303"
        idle()
        assert npages() == 1
        assert post("discard") == "303"
        idle()
        assert npages() == 0

    with subtest("printer asleep: clear error"):
        printer.succeed("touch /var/lib/fake-escl/asleep")
        assert post("scan") == "303"
        p = idle()
        assert "Remote Scanner" in p and "msg err" in p, p
        assert npages() == 0
        printer.succeed("rm /var/lib/fake-escl/asleep")

    with subtest("endless eSCL body is cut off"):
        printer.succeed("touch /var/lib/fake-escl/huge")
        assert post("scan") == "303"
        assert "64 MiB" in err(idle())
        assert npages() == 0
        printer.succeed("rm /var/lib/fake-escl/huge")

    with subtest("two pages + finish, delivered once the vault is mounted"):
        assert post("scan") == "303"
        idle()
        assert post("scan") == "303"
        idle()
        assert npages() == 2
        # The job's Location names another host; only the path is used.
        printer.succeed("grep -q 'GET /eSCL/ScanJobs/job.*/NextDocument' /var/lib/fake-escl/requests.log")
        printer.succeed("grep -q '<scan:XResolution>300</scan:XResolution>' /var/lib/fake-escl/last-settings.xml")
        assert post("finish") == "303"
        p = idle()
        assert "Saved" in p, p
        name = grab(r"<li>(\d{4}-\d\d-\d\d_\d{6}\.pdf)", p)
        year = name[:4]
        # /vault/misc is not mounted yet: the scan waits in the outbox.
        server.succeed(f"test -f /var/lib/scan-outbox/{name}")
        server.fail("ls -A /vault/misc | grep .")
        assert "waiting for the vault" in p
        server.succeed("mount -t tmpfs -o mode=2770,gid=1101 tmpfs /vault/misc")
        server.succeed("setfacl -m g:vault:rwx -m d:g:vault:rwx /vault/misc")
        f = f"/vault/misc/scans/{year}/{name}"
        FIRST = f
        server.wait_until_succeeds(f"test -f {f}", timeout=30)
        server.fail(f"test -e /var/lib/scan-outbox/{name}")
        assert server.succeed(f"stat -c '%U %a' {f}").strip() == "dave 600"
        assert server.succeed(f"stat -c '%U %a' /vault/misc/scans/{year}").strip() == "dave 700"
        # No ACLs at all (the parent's default ACL is not inherited).
        for d in (f, f"/vault/misc/scans/{year}", "/vault/misc/scans"):
            acl = server.succeed(f"getfacl -cp {d}")
            assert "group:vault" not in acl and "mask" not in acl, acl
        server.succeed(f"pdfinfo {f} | grep -q 'Pages: *2'")
        text = server.succeed(f"pdftotext {f} -")
        print(text)
        assert "Rechnung" in text and "Nummer" in text, "German text missing"
        assert "Invoice" in text, "English text missing"
        assert "ครับ" in text, "Thai text missing"
        assert npages() == 0
        assert "waiting for the vault" not in page()

    with subtest("scan + finish"):
        assert post("scanfinish") == "303"
        p = idle()
        assert "Saved" in p, p
        server.wait_until_succeeds("test $(ls /vault/misc/scans/*/*.pdf | wc -l) -eq 2", timeout=30)
        assert len(re.findall(r"<li>", page())) == 2

    with subtest("600 dpi colour page fits the OCR worker's MemoryMax"):
        t = token()
        assert post("scanfinish", data=f"token={t}&do=scanfinish&dpi=600&mode=color") == "303"
        p = idle()
        assert "Saved" in p, p
        printer.succeed("grep -q '<scan:XResolution>600</scan:XResolution>' /var/lib/fake-escl/last-settings.xml")
        server.wait_until_succeeds("test $(ls /vault/misc/scans/*/*.pdf | wc -l) -eq 3", timeout=30)
        j = server.succeed("journalctl -o cat -u 'scan-ocr@*' | grep -E 'memory.peak|oom|Killed' || true")
        print(j)
        peak = int(grab(r"ocr 1 page\(s\).*memory.peak=(\d+)", j))
        assert peak < 2 * 1024**3, peak
        assert "oom" not in j.lower()
        server.succeed("systemctl show -p PrivateNetwork,MemoryDenyWriteExecute,MemoryMax scan-ocr@probe.service | tee /dev/stderr | grep -q PrivateNetwork=yes")

    with subtest("page limit, full outbox"):
        for _ in range(3):
            assert post("scan") == "303"
            idle()
        assert npages() == 3
        assert post("scan") == "303"
        assert "at most 3 pages" in err(idle())
        assert npages() == 3
        assert post("discard") == "303"
        idle()
        server.succeed("truncate -s 3G /var/lib/scan-outbox/.filler.part")
        assert post("scan") == "303"
        assert "waiting for the vault" in err(idle())
        assert npages() == 0
        server.succeed("rm /var/lib/scan-outbox/.filler.part")

    with subtest("OCR worker refusing early: its error is shown"):
        # A page over the worker's 64 MiB cap: it replies ER after the
        # length, before the page is sent (BrokenPipe on our side).
        server.succeed("head -c 70000000 /dev/zero > /var/lib/scan-trigger/current/page-0001.jpg && chown scan-trigger /var/lib/scan-trigger/current/page-0001.jpg")
        assert npages() == 1
        assert post("finish") == "303"
        assert "OCR failed: page too large" in err(idle())
        assert post("discard") == "303"
        idle()
        assert npages() == 0

    with subtest("parallel clicks add one page"):
        t = token()
        desktop.succeed(
            f"for i in 1 2 3; do curl -s -o /dev/null {BROWSER} --data 'token={t}&do=scan' {URL}/action & done; wait"
        )
        idle()
        assert npages() == 1, npages()

    with subtest("leftover pages after a crash"):
        server.succeed("systemctl kill -s KILL scan-trigger.service")
        server.wait_until_succeeds("systemctl is-active scan-trigger.service", timeout=30)
        server.wait_for_open_port(8088, "192.168.8.250")
        p = page()
        assert "left over" in p and npages() == 1, p
        assert post("discard") == "303"
        idle()
        assert npages() == 0
        server.succeed("test -z \"$(ls -A /var/lib/scan-trigger/current)\"")

    with subtest("delivery: hostile outbox entries, no lock-out, no ACLs"):
        assert server.succeed("stat -c '%U:%G %a' /var/lib/scan-outbox").strip() == "root:scan-outbox 2770"
        server.fail("su -s /bin/sh scan-trigger -c 'chmod 0700 /var/lib/scan-outbox'")
        n0 = int(server.succeed("ls /vault/misc/scans/*/*.pdf | wc -l"))
        o = "/var/lib/scan-outbox"
        st = "su -s /bin/sh scan-trigger -c"
        server.succeed(f"{st} 'mkfifo {o}/2026-01-01_000001.pdf'")
        server.succeed(f"{st} 'echo hello > {o}/x.part; mv {o}/x.part {o}/2026-01-01_000002.pdf'")
        server.succeed(f"{st} 'printf %%PDF- > {o}/x.part; truncate -s 100M {o}/x.part; mv {o}/x.part {o}/2026-01-01_000003.pdf'")
        # The name already filed, same content: removed, not filed again.
        server.succeed(f"cp {FIRST} {o}/x.part && chown scan-trigger {o}/x.part && chmod 0640 {o}/x.part && mv {o}/x.part {o}/{name}")
        server.wait_until_succeeds(f"test -z \"$(ls -A {o})\"", timeout=60)
        assert int(server.succeed("ls /vault/misc/scans/*/*.pdf | wc -l")) == n0
        server.fail("ls /vault/misc/scans/*/*_dup*")
        server.succeed(f"journalctl -u scan-deliver | grep -q '{name} from the outbox: already filed'")
        server.succeed("systemctl is-active scan-deliver.service")
        # A recursive setfacl over the dataset is undone (sweep at start).
        server.succeed("setfacl -R -m g:vault:rwX -m d:g:vault:rwx /vault/misc")
        # Half-done copies: a stale one (crash mid-copy) is swept at
        # start, a fresh one (copy in progress) is left alone.
        y = f"/vault/misc/scans/{year}"
        server.succeed(f"su -s /bin/sh dave -c 'touch {y}/.old.pdf.part {y}/.new.pdf.part'")
        server.succeed(f"touch -d '2 days ago' {y}/.old.pdf.part")
        server.succeed("systemctl restart scan-deliver.service")
        server.wait_until_succeeds("! getfacl -Rcp /vault/misc/scans | grep -q vault", timeout=30)
        server.wait_until_succeeds(f"! test -e {y}/.old.pdf.part", timeout=30)
        server.succeed(f"test -e {y}/.new.pdf.part && rm {y}/.new.pdf.part")
        # The OCR socket is the web service's only.
        server.fail("su -s /bin/sh dave -c 'echo x | ${pkgs.socat}/bin/socat - UNIX-CONNECT:/run/scan-ocr/ocr.sock'")

    def held_back(why):
        n0 = int(server.succeed("ls /vault/misc/scans/*/*.pdf | wc -l"))
        assert post("scanfinish") == "303"
        p = idle()
        assert "Saved" in p, p
        name = grab(r"<li>(\d{4}-\d\d-\d\d_\d{6}(?:_\d+)?\.pdf)", p)
        server.wait_until_succeeds(f"journalctl -u scan-deliver | grep -q '{why}'", timeout=30)
        time.sleep(7)  # > pollSeconds: it really stays
        server.succeed(f"test -f /var/lib/scan-outbox/{name}")
        assert int(server.succeed("ls /vault/misc/scans/*/*.pdf | wc -l")) == n0
        assert "waiting for the vault" in page()
        return name

    with subtest("delivery: no room on outputDir -> scans wait"):
        # minFreeBytes is 64 MiB here: shrink the vault fs to ~40 MiB free.
        used = int(server.succeed("df -B1 --output=used /vault/misc | tail -1"))
        server.succeed(f"mount -o remount,size={used + 40 * 1024 * 1024} /vault/misc")
        name = held_back("would leave less than 64 MiB")
        server.succeed("mount -o remount,size=1G /vault/misc")
        server.wait_until_succeeds(f"test -f /vault/misc/scans/*/{name}", timeout=30)
        server.fail(f"test -e /var/lib/scan-outbox/{name}")

    with subtest("delivery: daily budget -> scans wait"):
        today = server.succeed("date +%F").strip()
        server.succeed(f"""echo '{{"day": "{today}", "bytes": 2147483000}}' > /var/lib/scan-deliver/budget.json""")
        name = held_back("would exceed the daily 2048 MiB")
        # The next day (here: an old day in the file) it is filed.
        server.succeed("""echo '{"day": "2000-01-01", "bytes": 2147483000}' > /var/lib/scan-deliver/budget.json""")
        server.wait_until_succeeds(f"test -f /vault/misc/scans/*/{name}", timeout=30)
        b = server.succeed("cat /var/lib/scan-deliver/budget.json")
        assert "2147483000" not in b and today in b, b

    with subtest("hardening"):
        server.succeed("systemctl show scan-trigger -p User | grep -q scan-trigger")
        server.fail("su -s /bin/sh scan-trigger -c 'ls /vault/misc'")
        # scan-trigger's own namespace has no /vault at all.
        pid = server.succeed("systemctl show -p MainPID --value scan-trigger").strip()
        server.fail(f"nsenter -t {pid} -m test -e /vault/misc/scans")
        server.succeed("systemctl start ocr-probe.service")
        out = server.succeed("journalctl -o cat -u ocr-probe.service")
        print(out)
        assert "socketpair ok" in out, out
        assert "CONNECTED" not in out and "SEES" not in out, out
        assert "refused /run/dbus/system_bus_socket" in out, out
        print(server.succeed("systemd-analyze security scan-trigger.service scan-deliver.service scan-ocr@probe.service | grep -i overall"))
  '';
}
