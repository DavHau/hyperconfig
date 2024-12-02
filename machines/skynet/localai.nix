{lib, config, pkgs, ...}: let
  nixpkgsSource = builtins.fetchTarball {
    url = "https://github.com/DavHau/nixpkgs/tarball/8e9fb76591a3c06ef719e094f5a38cddac744f03";
    sha256 = "sha256:0jgyzl13fj6zr7b6wifmvgcyf81asmvmgxq90ygj6b355sga33x0";
  };
  pkgs-localai = import nixpkgsSource {
    system = pkgs.system;
    config.allowUnfreePredicate = pkg:
      lib.hasPrefix "cudatoolkit" (lib.getName pkg)
      || lib.hasPrefix "cuda_cudart" (lib.getName pkg)
      || lib.hasPrefix "cuda_nvcc" (lib.getName pkg)
      || lib.hasPrefix "libcublas" (lib.getName pkg);
  };
  local-ai = pkgs-localai.local-ai.override {
    with_cublas = true;
    # with_stablediffusion = true;
    # broken but fixed on nixpkgs PR
    # with_tinydream = true;
  };

in {
  environment.systemPackages = [
    local-ai
  ];

  systemd.services.localai = {
    description = "LocalAI";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "simple";
      Restart = "always";
      DynamicUser = true;
      StateDirectory = "localai";
    };
    script = ''
      ${local-ai}/bin/local-ai \
        --audio-path $STATE_DIRECTORY/audio \
        --backend-assets-path $STATE_DIRECTORY/assets \
        --image-path $STATE_DIRECTORY/images \
        --models-path $STATE_DIRECTORY/models \
        --upload-path $STATE_DIRECTORY/upload \
        --threads $(${pkgs.coreutils}/bin/nproc) \
        --galleries [{"name":"model-gallery", "url":"github:go-skynet/model-gallery/index.yaml"}]

        # TODO: preload models we regularly use
        # --preload-models '[{"url": "github:go-skynet/model-gallery/mistral.yaml"}]'
    '';
  };
}
