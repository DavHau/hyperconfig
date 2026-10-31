# WABT for REA's wasm tools: REA accepts exactly release 1.0.42 (each of
# wasm-validate, wasm-objdump and wasm2wat must print `1.0.42` for
# `--version`; its result schema pins that release). nixpkgs has 1.0.41;
# its recipe derives the tag and the reported version from `version`.
{ fetchFromGitHub, wabt }:
wabt.overrideAttrs (
  finalAttrs: _: {
    version = "1.0.42";
    src = fetchFromGitHub {
      owner = "WebAssembly";
      repo = "wabt";
      tag = finalAttrs.version;
      hash = "sha256-33XpYt42Jw2xfwBR64jVI3VYVIKD1YjND9SSI6CdkaM=";
      fetchSubmodules = true;
    };
  }
)
