{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.oo7.daemon;
in
{
  options.services.oo7.daemon = {
    enable = lib.mkEnableOption "oo7-daemon Secret Service provider";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.oo7-server;
      description = "The oo7-server (oo7-daemon) package to use.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Prevent two Secret Service providers fighting over org.freedesktop.secrets.
    assertions = [
      {
        assertion = !config.services.gnome.gnome-keyring.enable;
        message = ''
          services.oo7.daemon and services.gnome.gnome-keyring cannot both be enabled.
          Both register as org.freedesktop.secrets providers. Disable one of them.
        '';
      }
    ];

    # Register the D-Bus service so oo7-daemon is activated on demand
    # when anything queries org.freedesktop.secrets.
    services.dbus.packages = [cfg.package];

    # Install the systemd user service shipped by oo7-server.
    # The package provides ExecStart and security hardening.
    # NixOS ignores [Install] sections from systemd.packages, so we
    # must declare wantedBy explicitly.
    systemd.packages = [cfg.package];
    systemd.user.services.oo7-daemon.wantedBy = ["default.target"];

    # Disable gnome-keyring by default to avoid conflicts.
    services.gnome.gnome-keyring.enable = lib.mkDefault false;
  };
}
