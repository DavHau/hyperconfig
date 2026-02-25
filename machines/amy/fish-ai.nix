{ pkgs, lib, inputs, ... }:
let
  version = "2.10.2";

  src = pkgs.fetchFromGitHub {
    owner = "Realiserad";
    repo = "fish-ai";
    rev = "v${version}";
    hash = "sha256-2LYgpE26FP+enUz0+h6OCdp8Tb9kRAVFL/eCwx1Cm1Q=";
  };

  python = pkgs.python3;
  pythonPackages = pkgs.python3Packages;

  # Patch iterfzf to use system fzf instead of bundled
  iterfzf = pythonPackages.iterfzf.overridePythonAttrs (old: {
    doCheck = false;
    postPatch = (old.postPatch or "") + ''
      substituteInPlace iterfzf/__init__.py \
        --replace-fail "Path(__file__).parent / EXECUTABLE_NAME" "None"
    '';
  });

  # Build fish-ai as a Python package
  fishAiPython = pythonPackages.buildPythonApplication {
    pname = "fish-ai";
    inherit version src;
    pyproject = true;

    build-system = [ pythonPackages.setuptools ];

    dependencies = with pythonPackages; [
      openai
      anthropic
      keyring
      groq
      cohere
      binaryornot
      google-genai
      simple-term-menu
      iterfzf
    ];

    doCheck = false;
    dontCheckRuntimeDeps = true;
  };

  # Create a venv-like structure that fish-ai expects at ~/.local/share/fish-ai
  fishAiEnv = pkgs.runCommand "fish-ai-env" { } ''
    mkdir -p $out/bin
    for f in ${fishAiPython}/bin/*; do
      ln -s "$f" "$out/bin/$(basename "$f")"
    done
    ln -sf ${python}/bin/python3 $out/bin/python3
  '';
in
{
  home-manager.users.grmpf = {
    xdg.dataFile."fish-ai".source = fishAiEnv;

    home.activation.initFishAiConfig = inputs.home-manager.lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      cp ${./fish-ai.ini} "$HOME/.config/fish-ai.ini"
      chmod u+w "$HOME/.config/fish-ai.ini"
    '';

    programs.fish.plugins = [
      {
        name = "fish-ai";
        inherit src;
      }
    ];
  };
}
