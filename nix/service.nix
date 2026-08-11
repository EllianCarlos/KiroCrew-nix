# Shared definition of the `services.kirocrew` user service.
#
# Upstream's `kirocrew service install` writes an imperative unit into
# /etc/systemd/system. That does not survive a NixOS rebuild, so the NixOS and
# home-manager modules render the same service declaratively instead. Both
# import this file so a change to the exec line or the environment cannot land
# in one module and not the other.
{ lib }:
rec {
  options = {
    enable = lib.mkEnableOption "the Kiro Crew gateway as a systemd user service";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The kirocrew package to run.";
    };

    port = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      example = 5477;
      description = ''
        Dashboard port. `KIROCREW_PORT` is the only input the gateway reads for
        this, so it must be set here rather than in the config file when the
        default 5476 is taken. Null leaves the gateway's own default in place.
      '';
    };

    home = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/kirocrew";
      description = ''
        Value for `KIROCREW_HOME`, the data home holding config, sessions, and
        memory. Null uses the default, `~/.kiro/crew`.
      '';
    };

    kiroBin = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/home/alice/.local/bin/kiro-cli";
      description = ''
        Absolute path to the `kiro-cli` binary. Kiro Crew is KiroACP-only and
        cannot answer a prompt without it. Null falls back to the package's own
        discovery: `$KIROCREW_KIRO_BIN`, then `~/.local/bin`, `~/.cargo/bin`,
        then `$PATH`.
      '';
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--no-crons" ];
      description = "Extra arguments appended to `kirocrew gateway`.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        KIROCREW_LOG_LEVEL = "DEBUG";
      };
      description = "Extra environment variables for the gateway process.";
    };
  };

  # `--no-open`: a service has no session to open a browser into, and the
  # startup attempt logs a failure on every boot.
  execStart =
    cfg: "${lib.getExe cfg.package} gateway --no-open ${lib.escapeShellArgs cfg.extraFlags}";

  environment =
    cfg:
    lib.filterAttrs (_: v: v != null) {
      # A user unit inherits no login locale. Without a UTF-8 one, a
      # subprocess reading a non-ASCII file dies on the ASCII codec — the same
      # reason service/common.py pins it for the imperative unit.
      LC_ALL = "C.UTF-8";
      LANG = "C.UTF-8";
      KIROCREW_PORT = if cfg.port == null then null else toString cfg.port;
      KIROCREW_HOME = cfg.home;
      KIROCREW_KIRO_BIN = cfg.kiroBin;
    }
    // cfg.environment;

  assertions = cfg: [
    {
      assertion = cfg.kiroBin == null || lib.hasPrefix "/" cfg.kiroBin;
      message = "services.kirocrew.kiroBin must be an absolute path (a service starts from an unspecified working directory).";
    }
  ];
}
