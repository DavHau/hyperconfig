#!/usr/bin/env bash
# cache.nixos.org: the served .nar.zst differs from the narinfo's FileSize/FileHash.
set -eu
c=https://cache.nixos.org
curl -s $c/39lyf5g2iz4jd2r6q4g5whk9vw09zglj.narinfo | grep -E '^(URL|FileSize|FileHash)'
curl -s $c/nar/0x5qyx7cddlgkp769yrc9c37zkpl5852612il53qq21bi50748pa.nar.zst -o /tmp/f.nar.zst
echo "served: FileSize: $(stat -c %s /tmp/f.nar.zst)"
echo "served: FileHash: sha256:$(nix hash file --type sha256 --base32 /tmp/f.nar.zst)"
