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
      default = ["login" "greetd"];
      example = ["login" "greetd" "swaylock" "hyprlock"];
      description = ''
        PAM services to add oo7 auto-unlock to.
        Defaults to login and greetd. Add screen lockers or
        other greeters (gdm, sddm) as needed.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # PAM configuration for auto-unlock at login.
    #
    # Auth phase: must run AFTER pam_unix (order 11700) so that
    # PAM_AUTHTOK is populated with the login password. pam_oo7
    # reads PAM_AUTHTOK and stashes it for the session phase.
    #
    # Session phase: must run AFTER pam_systemd (order 12000) which
    # starts systemd --user and makes D-Bus available. pam_oo7
    # retrieves the stashed password and sends it to oo7-daemon
    # via the PAM listener socket to unlock the default collection.
    security.pam.services =
      let
        pamConfig = {
          rules = {
            auth.oo7 = {
              order = 11800;
              control = "optional";
              modulePath = "${pamPkg}/lib/security/pam_oo7.so";
            };
            session.oo7 = {
              order = 12100;
              control = "optional";
              modulePath = "${pamPkg}/lib/security/pam_oo7.so";
              args = ["auto_start"];
            };
          };
        };
      in
        lib.genAttrs cfg.services (_: pamConfig);
  };
}
