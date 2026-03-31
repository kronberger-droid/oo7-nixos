{
  config,
  lib,
  pkgs,
  oo7-pam ? null,
  ...
}:

let
  cfg = config.services.oo7.pam;
  pamPkg =
    if oo7-pam != null
    then oo7-pam
    else cfg.package;
in
{
  options.services.oo7.pam = {
    enable = lib.mkEnableOption "oo7 PAM auto-unlock (unlock keyring at login)";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The oo7-pam package providing pam_oo7.so.";
    };

    services = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["swaylock" "hyprlock"];
      description = ''
        Additional PAM services to add oo7 auto-unlock to.
        Login/greeter services (login, greetd, gdm) are always included.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # PAM configuration for auto-unlock at login.
    #
    # The session module runs AFTER pam_systemd.so (which starts
    # systemd --user and makes D-Bus available). At that point
    # oo7-daemon can be D-Bus activated, and pam_oo7.so sends
    # the login password to unlock the default collection.
    #
    # mkOrder 12500 ensures we come after pam_systemd.so (typically
    # at ~10000) but before session cleanup.
    security.pam.services =
      let
        pamConfig = {
          rules = {
            auth.oo7 = {
              order = 12500;
              control = "optional";
              modulePath = "${pamPkg}/lib/security/pam_oo7.so";
            };
            session.oo7 = {
              order = 12500;
              control = "optional";
              modulePath = "${pamPkg}/lib/security/pam_oo7.so";
              args = ["auto_start"];
            };
          };
        };
        # Always include login-type services.
        loginServices = ["login" "greetd" "gdm" "sddm"];
        allServices = loginServices ++ cfg.services;
      in
        lib.genAttrs allServices (_: pamConfig);
  };
}
