# home-manager module: `services.kirocrew`.
#
# The non-NixOS half of the pair. Same options and same rendered service as
# nixos-module.nix (both import ./service.nix); only the systemd unit schema
# differs — home-manager takes the raw `[Unit]`/`[Service]`/`[Install]`
# sections, NixOS takes its own typed attributes.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  svc = import ./service.nix { inherit lib; };
  cfg = config.services.kirocrew;
in
{
  options.services.kirocrew = svc.options // {
    package = svc.options.package // {
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.kirocrew;
      defaultText = lib.literalExpression "kirocrew.packages.\${system}.kirocrew";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = svc.assertions cfg;

    home.packages = [ cfg.package ];

    systemd.user.services.kirocrew = {
      Unit = {
        Description = "Kiro Crew gateway (dashboard + channels)";
        Documentation = "https://github.com/kirodotdev/KiroCrew";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };

      Service = {
        ExecStart = svc.execStart cfg;
        # Quoted the way NixOS' own systemd generator emits it: systemd splits
        # an unquoted assignment on whitespace, so a value with a space in it
        # (a KIROCREW_HOME under a path like /home/a b/) would silently
        # truncate.
        Environment = lib.mapAttrsToList (k: v: ''"${k}=${v}"'') (svc.environment cfg);
        Restart = "on-failure";
        RestartSec = 5;
        # See nixos-module.nix for why these two are not systemd's defaults.
        TasksMax = 4096;
        TimeoutStopSec = 90;
      };

      Install.WantedBy = [ "default.target" ];
    };
  };
}
