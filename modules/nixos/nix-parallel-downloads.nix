{lib, ...}: {
  # Chunked parallel downloads of single large files from substituters.
  # Requires the custom nix from the parallel-downloads branch (see the
  # `nix` flake input override); stock nix ignores the unknown setting
  # with a warning.
  nix.settings = {
    # Any file larger than this is fetched as parallel byte-range chunks.
    # Worst-case reassembly memory ~= http-connections * chunk size (256M).
    parallel-download-chunk-size = "8M";
    # nix-gc.nix sets 200; with chunked downloads a single large file can
    # occupy the whole idle pool, so keep the total bounded.
    http-connections = lib.mkForce 32;
  };
}
