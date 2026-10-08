/*
  Shared Rust compile cache (sccache) and out-of-tree cargo build dirs.

  - RUSTC_WRAPPER=sccache for every cargo build. Dependencies hit the cache
    across sessions and omp worktrees; incrementally-built workspace crates
    and linked crates (bin, proc-macro, cdylib) are never cached by sccache.
  - build.build-dir moves target/'s intermediate artifacts (deps/,
    incremental/, build scripts) to ~/.cache/cargo-build<workspace path>
    (inside sbox: ~/.cargo/build-dir<workspace path>, persisted per
    project); ./target keeps only final artifacts, so worktree copies stay
    small. Keyed by the readable workspace path ({workspace-root}), not
    {workspace-path-hash}, so cargo-build-gc (./disk-hygiene) can tell when
    a build dir's workspace is gone — every omp task worktree is a new
    workspace path with its own multi-GB build dir — and deletes it within
    the hour; build dirs untouched for 14 days go too.

  Trust boundary: one cache per sbox project. Inside sbox the cache dirs
  are `persist` paths, backed per project under
  ~/.local/state/sbox/projects/<project>/persist, so a sandbox can only ever
  poison its own project's cache. The host cache is never bound into a
  sandbox. The sccache server listens on a unix socket in a private
  directory instead of TCP 127.0.0.1:4226, which `--network host` sandboxes
  (sharing the host loopback) could otherwise reach across sandboxes.
*/
{ pkgs, ... }:
let
  common = {
    RUSTC_WRAPPER = "${pkgs.sccache}/bin/sccache";
    # Per cache, i.e. per sbox project; sccache evicts LRU entries itself.
    SCCACHE_CACHE_SIZE = "30G";
  };
in
{
  environment.systemPackages = [ pkgs.sccache ];

  # /etc/set-environment exports these in double quotes: $HOME and
  # $XDG_RUNTIME_DIR expand per user; {workspace-root} is a cargo path
  # template and stays literal.
  environment.variables = common // {
    CARGO_BUILD_BUILD_DIR = "$HOME/.cache/cargo-build{workspace-root}";
    SCCACHE_SERVER_UDS = "$XDG_RUNTIME_DIR/sccache.sock";
  };

  programs.sbox = {
    # sccache's default SCCACHE_DIR is ~/.cache/sccache.
    persist = [
      "$HOME/.cache/sccache"
      "$HOME/.cargo/build-dir"
      "$HOME/.cargo/registry"
      "$HOME/.cargo/git"
    ];
    # --setenv values are literal (no $HOME), and sandboxes started outside
    # a login shell never see /etc/set-environment: name the build dir via
    # cargo's {cargo-cache-home} (= ~/.cargo) template instead, persisted
    # above. The socket goes to the session's private /tmp: one server per
    # session, all sessions of a project sharing the persisted disk cache.
    environment = common // {
      CARGO_BUILD_BUILD_DIR = "{cargo-cache-home}/build-dir{workspace-root}";
      SCCACHE_SERVER_UDS = "/tmp/sccache.sock";
    };
  };
}
