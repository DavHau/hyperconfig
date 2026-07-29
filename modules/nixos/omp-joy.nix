{
  pkgs,
  inputs,
  lib,
  ...
}: let
  sys = pkgs.stdenv.hostPlatform.system;
  # `llm-agents-cached`, NOT `llm-agents`: the latter has
  # inputs.nixpkgs.follows = "nixpkgs", which rehashes every derivation away
  # from what numtide's CI built -- omp then compiles from source on every
  # bump. The cached input keeps upstream's own nixpkgs, so these two paths
  # substitute straight from cache.numtide.com (verified 2026-07-29: narinfo
  # 200 for both). Joy's laptop must update fast, and it takes both packages
  # as-is, so the duplicated nixpkgs closure is worth it here.
  agents = inputs.llm-agents-cached.packages.${sys};
  # Upstream claude-desktop is a prebuilt Electron app. At GPU init its ANGLE
  # backend dlopens libEGL.so.1 -- the GLVND *dispatch* loader -- by soname.
  # NixOS's /run/opengl-driver/lib ships only mesa's *vendor* lib
  # (libEGL_mesa.so.0); libEGL.so.1 lives in libglvnd, which is on no default
  # search path here, so the dlopen fails, the GPU process exits, and the
  # renderer paints nothing -> the white window joy saw (verified on joy
  # 2026-07-29: "ANGLE Display::initialize error 12289: Could not dlopen
  # native EGL: libEGL.so.1"; gone once both dirs are on LD_LIBRARY_PATH).
  # symlinkJoin + wrapProgram only mints a tiny wrapper -- the big Electron
  # closure still substitutes from cache.numtide.com.
  claude-desktop = pkgs.symlinkJoin {
    name = "claude-desktop-glwrapped";
    paths = [ agents.claude-desktop ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/claude-desktop \
        --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath [ pkgs.libglvnd ]}:${pkgs.addDriverRunpath.driverLink}/lib"
    '';
  };
in {
  # Native Wayland for Electron/Chromium apps (Plasma6 Wayland session): the
  # upstream claude-desktop wrapper gates its --ozone-platform flags on this.
  environment.sessionVariables.NIXOS_OZONE_WL = "1";

  environment.systemPackages = [
    # Barebones omp: no wrapper, no pinned config.yml, no rules/skills/model
    # providers (unlike pi.nix / omp-common.nix on dave's machines). Joy
    # configures her own ~/.omp.
    agents.omp
    # Anthropic's desktop GUI client (GL-wrapped, see above).
    claude-desktop
  ];

  # Working copy of this config in joy's $HOME. Cloned once over https (the
  # repo is public, so no deploy key needed) and never touched again -- pulling
  # would clobber whatever she has in flight. Removing the clone makes the unit
  # recreate it on the next boot.
  systemd.services.joy-hyperconfig-clone = {
    description = "Clone hyperconfig into joy's home";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    unitConfig.ConditionPathExists = "!/home/joy/hyperconfig";
    path = [ pkgs.git pkgs.openssh ];
    serviceConfig = {
      Type = "oneshot";
      User = "joy";
      Group = "users";
      RemainAfterExit = true;
    };
    script = ''
      git clone https://github.com/DavHau/hyperconfig.git /home/joy/hyperconfig
      cd /home/joy/hyperconfig
      # Push target for her own commits; https stays as the fetch fallback.
      git remote set-url --push origin git@github.com:DavHau/hyperconfig.git
    '';
  };
}
