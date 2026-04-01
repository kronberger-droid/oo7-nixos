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

  # Wait for oo7-daemon to create its PAM listener socket.
  #
  # pam_systemd (order 12000) starts oo7-daemon asynchronously via
  # systemd --user. The daemon needs a moment to bind its PAM socket.
  # Without this wait, pam_oo7 (order 12100) races the daemon and
  # silently fails to connect, leaving the keyring locked.
  waitForPamSocket = pkgs.writeShellScript "oo7-wait-for-pam-socket" ''
    sock="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/oo7-pam.sock"
    for _ in $(seq 1 20); do
      [ -S "$sock" ] && exit 0
      sleep 0.1
    done
    exit 0
  '';
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
    # Auth phase: NixOS's default pam_unix uses `sufficient` control
    # (order 11700). When it succeeds, PAM stops processing further
    # auth rules — so anything after it never runs.
    #
    # To capture PAM_AUTHTOK before the stack terminates, we insert
    # an `optional` pam_unix early run (order 11500) that validates
    # the password and populates PAM_AUTHTOK, then pam_oo7 (order
    # 11600) stashes it. The existing `sufficient` pam_unix at 11700
    # uses `try_first_pass` and succeeds without re-prompting.
    #
    # This is the same split pattern gnome-keyring uses.
    #
    # Session phase: must run AFTER pam_systemd (order 12000) which
    # starts systemd --user and makes D-Bus available. pam_oo7
    # retrieves the stashed password and sends it to oo7-daemon
    # via the PAM listener socket to unlock the default collection.
    #
    # Race condition mitigation: pam_systemd starts oo7-daemon
    # asynchronously — the daemon needs time to bind its PAM socket.
    # A pam_exec wait step (order 12050) polls for the socket before
    # pam_oo7 (order 12100) tries to connect.
    security.pam.services =
      let
        pamConfig = {
          rules = {
            auth.unix-early = {
              order = 11500;
              control = "optional";
              modulePath = "${pkgs.pam}/lib/security/pam_unix.so";
              args = ["likeauth" "nullok"];
            };
            auth.oo7 = {
              order = 11600;
              control = "optional";
              modulePath = "${pamPkg}/lib/security/pam_oo7.so";
            };
            session.oo7-wait = {
              order = 12050;
              control = "optional";
              modulePath = "${pkgs.pam}/lib/security/pam_exec.so";
              args = ["quiet" "${waitForPamSocket}"];
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
