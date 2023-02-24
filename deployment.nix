{config, lib, ...}: {
  options.deployAddress = lib.mkOption {
    type = lib.types.str;
    description = "The address to reach the host over the internet";
  };
}
