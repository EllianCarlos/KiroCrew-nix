# NixOS module: `services.kirocrew`.
#
# Kiro Crew is a per-user agent — it reads and writes the invoking user's
# files and holds that user's credentials — so this renders a systemd *user*
# service, never a system one. Enable it per user with
# `systemctl --user enable --now kirocrew`, or set `startAtLogin`.
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

    startAtLogin = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Start the gateway automatically when a user session begins. Off by
        default: the unit is defined for every user on the system, and an agent
        that holds credentials should be an explicit per-user opt-in
        (`systemctl --user enable --now kirocrew`).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = svc.assertions cfg;

    environment.systemPackages = [ cfg.package ];

    systemd.user.services.kirocrew = {
      description = "Kiro Crew gateway (dashboard + channels)";
      documentation = [ "https://github.com/kirodotdev/KiroCrew" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = lib.optional cfg.startAtLogin "default.target";

      environment = svc.environment cfg;

      serviceConfig = {
        ExecStart = svc.execStart cfg;
        Restart = "on-failure";
        RestartSec = 5;
        # The gateway reaps kiro-cli and MCP children in bursts; the default
        # cgroup task limit is low enough to kill it seconds after startup.
        TasksMax = 4096;
        # Long enough for the gateway's own staged shutdown to finish flushing
        # session state before systemd escalates to SIGKILL.
        TimeoutStopSec = 90;
      };
    };
  };
}
