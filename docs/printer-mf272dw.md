# Canon i-SENSYS MF272dw: printing and scanning

The printer (`printer.lan`) sits on the isolated IoT Wi-Fi at the fixed address
192.168.18.20 (no internet, cannot reach the LAN). The home LAN
192.168.8.0/24 reaches it; it never connects to us.

- **Printing**: driverless IPP (AirPrint / IPP Everywhere) from amy, vit
  and joy. Queue `canon`, `ipp://192.168.18.20/ipp/print`, default
  printer, A4, two-sided long edge. Module:
  `modules/nixos/printer-canon-mf272dw.nix` (logic in
  `modules/nixos/lan-printer.nix`).
- **Scanning**: the MF272dw can't push scans anywhere (no scan-to-folder,
  JPEG only on the device). bam pulls them over eSCL ("Network Link
  Scan") from a LAN web page: **http://192.168.8.250:8088/**. Module:
  `modules/nixos/scan-trigger/`, bam instance: `machines/bam/scan-trigger.nix`.
  Finished documents are searchable PDFs (OCR deu+eng+tha) in
  `/vault/misc/scans/<year>/<YYYY-MM-DD_HHMMSS>.pdf`, Dave's files, mode
  0600, no ACLs (the vault group has no access; scan-deliver strips
  ACLs a recursive `setfacl` may add). OCR runs in a separate per-document
  unit without network (`scan-ocr@`), since it parses the printer's JPEGs.

## Using the scan page

1. Put a page face down on the glass, click **Scan page**. Repeat for
   every page of the document.
2. **Finish document** builds one PDF, OCRs it and files it. **Discard**
   drops the collected pages. **Scan + finish** = one-page document.
3. Resolution (150/300/600 dpi, default 300) and colour/grey apply to the
   next scan.

If the page says the printer is not reachable or refused the scan: on the
printer press **Scan → Remote Scanner** (puts it online) and click again.
Pages scanned so far are kept (also across a restart of the service).
While `/vault/misc` is not mounted (bam's vault datasets need their key
after a boot) finished scans wait in `/var/lib/scan-outbox` and are filed
automatically once it is; the page marks them "waiting for the vault".
Limits: at most 50 pages per document; no new scan while less than 2 GB
is free on /var/lib or 2 GB of finished scans wait for the vault; OCR of
one document may take 10 minutes (`journalctl -u 'scan-ocr@*'`).

## One-time settings on the printer

Remote UI: `http://192.168.18.20/` (System Manager Mode), or the panel.

1. Network → AirPrint Settings → **Use AirPrint: On** (also switches on
   IPP, HTTP and Network Link Scan).
2. Network → TCP/IP Settings → Network Link Scan Settings → **Use Network
   Link Scan: On** (check, if not already on through AirPrint).
3. Panel: Function Settings → Common → Scan Settings → **Auto Online: On**
   (default On), so a scan request from bam is accepted without pressing
   Remote Scanner first.
4. Keep "Allow IPP Printing Only When Using TLS" **Off** and IPP
   authentication off (the queue uses plain `ipp://`, scan pulls plain
   `http://`; the traffic stays between LAN and the isolated IoT net).
5. Security: set the **System Manager ID + PIN** (Management Settings →
   User Management) and the **Remote UI Access PIN**; by default anyone
   on the network can change settings.
6. No firmware updates: Update Firmware → Notification Settings **Off**,
   never "Via Internet". Optional: LPD, RAW, WSD off (unused).
7. If you set the device's inbound IP filter, allow the address the
   printer sees for LAN clients (192.168.8.0/24, or the router's
   192.168.18.1 if the router NATs LAN→IoT).

## Why not `hardware.printers.ensurePrinters`

It runs `lpadmin -m everywhere` in cups.service's postStart under
`set -e`; `-m everywhere` needs the printer online to build the PPD, so a
deploy while the printer is off fails cups and the switch. Our
`lan-printer-canon.timer` creates the queue 20 s after boot/switch and
retries every 15 min; while the printer is off it logs "not reachable" and
exits 0. So right after the first deploy the queue appears only once the
printer has been on during one of those runs (or run
`systemctl start lan-printer-canon` by hand).
