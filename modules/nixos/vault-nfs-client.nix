# Mount bam's vault pool at /vault over NFSv4.2, via the wg-vault kernel
# WireGuard star (bam.wg-vault comes from the instance's /etc/hosts entries).
#
# Automount + nofail: boots, `df` and file managers never hang while bam is
# down; the mount materializes on first access and idles away after 10 min.
# Default `hard` semantics are kept deliberately - `soft` trades hangs for
# silent write corruption.
{
  fileSystems."/vault" = {
    device = "bam.wg-vault:/vault";
    fsType = "nfs";
    options = [
      "nfsvers=4.2"
      # Match the vault datasets' 1M recordsize.
      "rsize=1048576"
      "wsize=1048576"
      "nconnect=4"
      "noauto"
      "nofail"
      "x-systemd.automount"
      "x-systemd.idle-timeout=600"
    ];
  };
}
