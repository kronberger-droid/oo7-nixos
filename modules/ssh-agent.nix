{
  config,
  lib,
  oo7-ssh-agent,
  ...
}:

let
  cfg = config.services.oo7.sshAgent;
  daemonCfg = config.services.oo7.daemon;
  socketName = "oo7-ssh-agent.sock";
in
{
  options.services.oo7.sshAgent = {
    enable = lib.mkEnableOption "oo7 SSH agent backed by org.freedesktop.secrets";

    package = lib.mkOption {
      type = lib.types.package;
      default = oo7-ssh-agent;
      description = "The oo7-ssh-agent package to use.";
    };

    socketPath = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Override the SSH agent socket path.
        Defaults to `$XDG_RUNTIME_DIR/oo7-ssh-agent.sock`
        (i.e., `/run/user/<uid>/oo7-ssh-agent.sock`).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Systemd user socket — created by systemd with correct permissions.
    # The agent binary is started on first connection.
    systemd.user.sockets.oo7-ssh-agent = {
      unitConfig = {
        Description = "oo7 SSH Agent Socket";
      };
      socketConfig = {
        ListenStream =
          if cfg.socketPath != null
          then cfg.socketPath
          else "%t/${socketName}";
        SocketMode = "0600";
      };
      wantedBy = ["sockets.target"];
    };

    # Systemd user service — socket-activated.
    systemd.user.services.oo7-ssh-agent = {
      unitConfig =
        {
          Description = "oo7 SSH Agent";
          Requires = ["oo7-ssh-agent.socket"];
        }
        // lib.optionalAttrs daemonCfg.enable {
          After = ["oo7-daemon.service"];
          Wants = ["oo7-daemon.service"];
        };
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/oo7-ssh-agent";
        Restart = "on-failure";
        RestartSec = 3;
        Environment = "RUST_LOG=warn";
      };
    };

    # Set SSH_AUTH_SOCK for login shells (sourced by greeter/PAM).
    environment.sessionVariables.SSH_AUTH_SOCK =
      if cfg.socketPath != null
      then cfg.socketPath
      else "/run/user/%U/${socketName}";
  };
}
