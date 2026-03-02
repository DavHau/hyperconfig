final: prev: {
  ollama = prev.ollama.overrideAttrs (old: rec {
    version = "0.17.4";
    src = final.fetchFromGitHub {
      owner = "ollama";
      repo = "ollama";
      tag = "v${version}";
      hash = "sha256-9yJ8Jbgrgiz/Pr6Se398DLkk1U2Lf5DDUi+tpEIjAaI=";
    };
    vendorHash = "sha256-Lc1Ktdqtv2VhJQssk8K1UOimeEjVNvDWePE9WkamCos=";
  });
}
