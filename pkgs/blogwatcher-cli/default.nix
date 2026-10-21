# blogwatcher-cli: tracks blogs (RSS/Atom, HTML fallback) and lists new
# articles; the daily Open LLM brief cron job of dave-hermes calls it. The
# same release amy's hermes microVM ran as a downloaded binary.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule rec {
  pname = "blogwatcher-cli";
  version = "0.2.1";

  src = fetchFromGitHub {
    owner = "JulienTant";
    repo = "blogwatcher-cli";
    rev = "v${version}";
    hash = "sha256-A4YoTPKTMVCG2t77wiUooNYGIY4VS7Sx6na/D2KKGu8=";
  };

  vendorHash = "sha256-fWHRGM83VbBwh3W9+PrNwxNwX2w/1sOe+c4z+yLI5cE=";

  subPackages = [ "cmd/blogwatcher-cli" ];

  ldflags = [
    "-s"
    "-w"
    "-X github.com/JulienTant/blogwatcher-cli/internal/version.Version=${version}"
  ];

  meta = {
    description = "Track blog articles and detect new posts";
    homepage = "https://github.com/JulienTant/blogwatcher-cli";
    license = lib.licenses.mit;
    mainProgram = "blogwatcher-cli";
  };
}
