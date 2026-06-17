## 2026-06-17 before replace 7HKT9T5N

root@nas ~# zpool status
  pool: pool11
 state: DEGRADED
status: One or more devices could not be used because the label is missing or
	invalid.  Sufficient replicas exist for the pool to continue
	functioning in a degraded state.
action: Replace the device using 'zpool replace'.
   see: https://openzfs.github.io/openzfs-docs/msg/ZFS-8000-4J
  scan: resilvered 312K in 00:00:06 with 0 errors on Wed Jun 17 14:14:43 2026
config:

	NAME                                   STATE     READ WRITE CKSUM
	pool11                                 DEGRADED     0     0     0
	  raidz3-0                             DEGRADED     0     0     0
	    ata-WDC_WD80EFAX-68KNBN0_VAHEDZ1L  ONLINE       0     0     0
	    15226270087997051931               UNAVAIL      0     0     0  was /dev/disk/by-id/ata-WDC_WD80EFAX-68LHPN0_7HKT9T5N-part1
	    15104155704982743977               UNAVAIL      0     0     0  was /dev/disk/by-id/ata-WDC_WD80EFAX-68LHPN0_7HKU9N1N-part1
	    ata-WDC_WD80EFAX-68LHPN0_7SGVTAKC  ONLINE       0     0     0
	    ata-WDC_WD80EFAX-68LHPN0_7SJSR5AW  ONLINE       0     0     1
	    ata-WDC_WD80EFZX-68UW8N0_VK0G9EMY  ONLINE       0     0     0
	    ata-WDC_WD80EFZX-68UW8N0_VK0L32JY  ONLINE       0     0     0
	    ata-WDC_WD80EFZX-68UW8N0_VK0RYZTY  ONLINE       0     0     0
	    ata-WDC_WD80EFZX-68UW8N0_VKJUM6XX  ONLINE       0     0     0
	    ata-WDC_WD80EFZX-68UW8N0_VKJUMY6X  ONLINE       0     0     0
	    ata-WDC_WD80EFZX-68UW8N0_VKKMZ1SX  ONLINE       0     0     0

### comments

still need to check if 7HKT9T5N actually broken
