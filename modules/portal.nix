{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.oo7.portal;
  daemonCfg = config.services.oo7.daemon;
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

    # Install the systemd user service shipped by oo7-portal.
    # The package unit already has correct ordering (After/PartOf
    # graphical-session.target, Wants xdg-desktop-portal.service)
    # and D-Bus activation config.
    systemd.packages = [cfg.package];
  };
}
