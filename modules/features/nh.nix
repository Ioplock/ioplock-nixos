{
  self,
  inputs,
  ...
}:
{
  flake.nixosModules.nh =
    { config, pkgs, lib, ... }:
    {
      system.nixos.label = lib.maybeEnv "NIXOS_LABEL" config.system.nixos.version;
      programs.nh = {
        enable = true;
        package = self.packages.${pkgs.stdenv.hostPlatform.system}.myNh;
      };
    };

  perSystem =
    { pkgs, lib, self', ... }:
    {
      packages.generateLabel = pkgs.writeShellApplication {
        name = "generate-label";
        runtimeInputs = [ pkgs.git ];
        text = ''
          branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null | tr '/' '.' || echo "unknown")
          if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
            stability="S"
          else
            stability="E"
          fi
          datetime=$(git log -1 --format=%cd --date=format:'%Y%m%d-%H%M%S' 2>/dev/null || date +%Y%m%d-%H%M%S)
          rev=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
          title=$(git log -1 --format='%s' 2>/dev/null | tr -cd 'a-zA-Z0-9 .:-' | tr ' ' '-' | head -c 64 || echo "no-commit")
          echo "$branch-$stability-$datetime-$rev-$title"
        '';
      };

      packages.myNh = inputs.wrapper-modules.lib.wrapPackage {
        inherit pkgs;
        package = pkgs.nh;
        extraPackages = [ self'.packages.generateLabel ];
        runShell = [
          ''
            export NIXOS_LABEL=$(generate-label 2>/dev/null || echo "unknown")
            exec ${lib.getExe pkgs.nh} "$@" -- --impure
          ''
        ];
      };
    };
}
