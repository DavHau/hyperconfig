# Home printer/scanner (USB on bam)

The home printer/scanner (model not fixed yet) is plugged into **bam** by
USB. bam drives it and serves it to the home LAN; nothing on the network
talks to the device itself. To serve it from another host: move
`machines/bam/printer.nix` (and its import) there and change `address`
in `modules/nixos/home-printer-server.nix` (read by bam and the desktops).

- **Driver**: IPP over USB (`ipp-usb`, driverless, no vendor driver).
  Most AirPrint/Mopria-certified printers and MFPs since ~2016 have it.
  ipp-usb exposes the device's IPP (print), eSCL (scan) and its own web
  admin page on **loopback only**, port **60000**
  (`http://localhost:60000/`), no DNS-SD, never on the LAN. udev starts
  `ipp-usb.service` when the device is plugged in; with no device nothing
  runs. Module: `modules/nixos/home-printer-host.nix`.
- **Printing**: bam's CUPS queue `home` (`ipp://localhost:60000/ipp/print`,
  driverless, A4) is shared to the LAN as
  **`ipp://192.168.8.250:631/printers/home`** (firewall: 192.168.8.0/24 on
  br0 only; cupsd lets the LAN reach that queue only, its web UI and admin
  pages stay on localhost; no browsing/announcements). amy, vit and joy
  have a queue `home` (default printer, A4) pointing there:
  `modules/nixos/home-printer.nix` (logic in `modules/nixos/lan-printer.nix`).
  Other LAN devices (phones) can add that URI by hand.
- **Scanning**: the scan page **http://192.168.8.250:8088/** on bam pulls
  pages over eSCL from ipp-usb (`http://localhost:60000/eSCL`). Module:
  `modules/nixos/scan-trigger/`, settings in `machines/bam/printer.nix`.
  Finished documents are searchable PDFs (OCR deu+eng+tha) in
  `/vault/misc/scans/<year>/<YYYY-MM-DD_HHMMSS>.pdf`, Dave's files, mode
  0600, no ACLs (the vault group has no access; scan-deliver strips ACLs
  a recursive `setfacl` may add). OCR runs in a separate per-document unit
  without network (`scan-ocr@`), since it parses the device's JPEGs.

Security: everything local on bam can reach loopback, so any local user
or service on bam can print and scan through ipp-usb. The device's web
page (its settings) is root-only (ipp-usb's uid check; under the unit's
PrivateUsers=true every other uid is nobody). That is the same trust as a
LAN client of the scan page. Set an admin PIN on the device itself if it
has one. No firmware updates (the device has no network anyway).

The CUPS share is **unauthenticated**: the user name a print job carries
is whatever the client claims, so a LAN host can pose as anyone. The LAN
therefore gets only printing and status (Print-Job, Create-Job,
Send-Document, Validate-Job, Get-Printer-Attributes, Get-Jobs,
Get-Job-Attributes: op policy `lan`). Cancelling, holding or fetching a
job, admin operations, device/driver listing and subscriptions are
localhost only (403 from the LAN, never a password prompt). Job files are
deleted when the job ends, the job list is kept 15 min, and job names and
owners are hidden. To cancel a stuck job: `cancel -a home` on bam as root.

## When the device arrives

1. Plug it into bam by USB, switch it on.
2. Check it speaks IPP over USB (on bam):
   ```
   lsusb                                    # find it
   lsusb -v -d <vid>:<pid> | grep -A2 'bInterfaceClass *7'
   # need an interface with bInterfaceSubClass 1, bInterfaceProtocol 4
   ipp-usb check                            # lists it if usable
   systemctl status ipp-usb                 # started by udev
   cat /var/lib/ipp-usb/dev/*.state         # its port (60000)
   curl -s http://localhost:60000/eSCL/ScannerCapabilities | head
   ```
3. The queue appears by itself ~20 s after ipp-usb starts (or
   `systemctl start lan-printer-home`), on the desktops within 15 min (or
   `systemctl start lan-printer-home` there). Print a test page from a
   desktop: `lp -d home /etc/os-release`.
4. Scan a page on http://192.168.8.250:8088/.

A second ipp-usb device would get port 60001; only the first is used.

## Fallback: no IPP over USB

If `lsusb -v` shows no 7/1/4 interface (only 7/1/2 = plain USB printer
class, or vendor-specific 255), ipp-usb can't drive it. Then (not built):
a vendor CUPS driver on bam (`services.printing.drivers`, e.g.
`brlaser`, `hplip`, `gutenprint`, `splix`) with a `usb://` queue
instead of `ipp://localhost:60000/ipp/print`, and for scanning a SANE
backend (`hardware.sane`, plus the vendor's backend) with scan-trigger
switched to calling `scanimage` instead of eSCL. Check the model on
openprinting.org first.

## Why not `hardware.printers.ensurePrinters`

It runs `lpadmin -m everywhere` in cups.service's postStart under
`set -e`; `-m everywhere` needs the printer online to build the PPD, so a
deploy while the printer is off (or unplugged) fails cups and the switch.
`lan-printer-home.timer` creates the queue 20 s after boot/switch and
retries every 15 min; while the printer is unreachable it logs "not
reachable" and exits 0.

## Using the scan page

1. Put a page face down on the glass, click **Scan page**. Repeat for
   every page of the document.
2. **Finish document** builds one PDF, OCRs it and files it. **Discard**
   drops the collected pages. **Scan + finish** = one-page document.
3. Resolution (150/300/600 dpi, default 300) and colour/grey apply to the
   next scan.

If the page says the printer is not reachable or refused the scan: check
it is on and plugged in (`systemctl status ipp-usb` on bam), wake it, and
click again. Pages scanned so far are kept (also across a restart of the
service). While `/vault/misc` is not mounted (bam's vault datasets need
their key after a boot) finished scans wait in `/var/lib/scan-outbox` and
are filed automatically once it is; the page marks them "waiting for the
vault". Limits: at most 50 pages per document; no new scan while less
than 2 GB is free on /var/lib or 2 GB of finished scans wait for the
vault; OCR of one document may take 10 minutes
(`journalctl -u 'scan-ocr@*'`).
