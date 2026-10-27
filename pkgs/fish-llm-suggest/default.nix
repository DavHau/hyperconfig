# pty proxy + suggestion daemon behind live LLM autosuggestions in fish
# (modules/nixos/fish-llm-suggest.nix). Standard library only.
{ runCommand, python3, makeWrapper }:
runCommand "fish-llm-suggest"
  {
    nativeBuildInputs = [ makeWrapper ];
    meta.mainProgram = "fish-llm-suggest";
  }
  ''
    install -Dm644 ${./fish-llm-suggest.py} $out/libexec/fish-llm-suggest.py
    ${python3.interpreter} -m py_compile $out/libexec/fish-llm-suggest.py
    makeWrapper ${python3.interpreter} $out/bin/fish-llm-suggest \
      --add-flags "-I $out/libexec/fish-llm-suggest.py"
  ''
