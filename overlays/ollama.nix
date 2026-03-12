final: prev: {
  ollama = prev.ollama.overrideAttrs (old: rec {
    version = "0.17.5";
    src = final.fetchFromGitHub {
      owner = "ollama";
      repo = "ollama";
      tag = "v${version}";
      hash = "sha256-MPcLs9O7GZoPLnpGq3LQU13j6Nhhb4InoeXLts6yncU=";
    };
    vendorHash = "sha256-Lc1Ktdqtv2VhJQssk8K1UOimeEjVNvDWePE9WkamCos=";
  });
}
