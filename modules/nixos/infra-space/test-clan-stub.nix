# What clan provides to ./default.nix in the VM tests (./test.nix,
# ./agent-tools-test.nix): the generator declarations (ignored here) and
# each file's deployed path, /etc/test-vars/<generator>/<file>.
{ lib, ... }:
{
  options.clan.core.vars.generators = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        let
          generator = name;
        in
        {
          freeformType = lib.types.attrsOf lib.types.anything;
          options.files = lib.mkOption {
            default = { };
            type = lib.types.attrsOf (
              lib.types.submodule (
                { name, ... }:
                {
                  freeformType = lib.types.attrsOf lib.types.anything;
                  options.path = lib.mkOption {
                    type = lib.types.str;
                    default = "/etc/test-vars/${generator}/${name}";
                  };
                }
              )
            );
          };
        }
      )
    );
  };
}
