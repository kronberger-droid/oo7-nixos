{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.oo7.portal;
in
{
  options.services.oo7.portal = {
    enable = lib.mkEnableOption "oo7-portal for xdg-desktop-portal Secret interface";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.oo7-portal;
      description = "The oo7-portal package to use.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Register the D-Bus service for portal activation.
    services.dbus.packages = [cfg.package];

    # Install the .portal file so xdg-desktop-portal discovers it.
    xdg.portal = {
      enable = true;
      extraPortals = [cfg.package];
    };

    # Systemd user service for the portal.
    systemd.user.services.oo7-portal = {
      unitConfig = {
        Description = "oo7 XDG Desktop Portal (Secret)";
        After = ["oo7-daemon.service"];
      };
      serviceConfig = {
        ExecStart = "${cfg.package}/libexec/oo7-portal";
        Restart = "on-failure";
      };
    };
  };
}
