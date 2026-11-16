# Stefan's parquet container slot (not his agent's slot `stefan`): root
# with his keys, /vault/parquet read-only. id 24, isolated, v6
# 2405:9800:b901:94e3::5107:18 (container slots: ./configuration.nix).
{
  services.container-slots.slots.stefan-pq = {
    id = 24;
    mode = "isolated";
    deployKeys = import ../../modules/nixos/users/stefan-keys.nix;
    # Reads land on bam as slot-stefan-pq:vault-ro, which bam's ACLs admit
    # read-only on /vault/parquet only (../../modules/nixos/vault-ids.nix).
    shares."/vault/parquet" = {
      source = "/vault/parquet";
      user = "slot-stefan-pq";
      readOnly = true;
    };
  };

  users.users.slot-stefan-pq = {
    isSystemUser = true;
    uid = 1219;
    group = "vault-ro";
    description = "stefan-pq container slot's read-only identity on /vault/parquet";
  };
}
