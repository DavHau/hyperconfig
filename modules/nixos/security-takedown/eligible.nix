# Units a security takedown (./takedowns.nix) may stop, per machine: the
# internet-exposed app services and nothing else (./default.nix refuses
# every other unit, and an unknown machine, at evaluation). A service's
# own module may add to `security.takedown.eligible` too. Only a session
# changes this list: sec-job-guard refuses it from the unattended jobs.
{
  # tasks.davhau.com and nc.davhau.com through edi's reverse proxy
  bam = [
    "vikunja.service"
    "phpfpm-nextcloud.service"
  ];
}
