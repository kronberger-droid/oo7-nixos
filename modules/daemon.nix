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

    # Register D-Bus services:
    # - oo7-daemon: activated when anything queries org.freedesktop.secrets
    # - gcr: provides org.gnome.keyring.SystemPrompter for graphical
    #   password dialogs (collection unlock/create). This is a lightweight
    #   GTK dialog, not the full gnome-keyring stack.
    services.dbus.packages = [cfg.package pkgs.gcr];

    # Install the systemd user service shipped by oo7-server.
    # The package provides ExecStart and security hardening.
    # NixOS ignores [Install] sections from systemd.packages, so we
    # must declare wantedBy explicitly.
    systemd.packages = [cfg.package];
    systemd.user.services.oo7-daemon = {
      wantedBy = ["default.target"];
      serviceConfig = {
        # The upstream unit sets PrivateUsers=yes which drops all
        # capabilities, and NoNewPrivileges=true blocks regaining them.
        # Override both so oo7-daemon can mlock() secrets in memory
        # instead of falling back to insecure allocations.
        PrivateUsers = lib.mkForce false;
        AmbientCapabilities = ["CAP_IPC_LOCK"];
        CapabilityBoundingSet = ["CAP_IPC_LOCK"];
      };
    };

    # Auto-create the Login collection with a "default" alias.
    #
    # oo7-daemon (unlike gnome-keyring) does not create a default
    # collection automatically. Without one, clients looking up
    # aliases/default get errors and fall back to slow retries.
    # This oneshot creates the collection once and is idempotent —
    # CreateCollection on an existing name returns the existing path.
    systemd.user.services.oo7-init-login = {
      description = "Create oo7 Login collection with default alias";
      after = ["oo7-daemon.service"];
      requires = ["oo7-daemon.service"];
      wantedBy = ["default.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = let
          initScript = pkgs.writeShellScript "oo7-init-login" ''
            busctl="${pkgs.systemd}/bin/busctl"

            # Wait for the daemon to be ready on DBus
            for _ in $(seq 1 30); do
              $busctl --user status org.freedesktop.secrets >/dev/null 2>&1 && break
              sleep 0.1
            done

            # Check if Login collection already exists via the default alias
            result=$($busctl --user call org.freedesktop.secrets \
              /org/freedesktop/secrets \
              org.freedesktop.Secret.Service ReadAlias "s" "default" 2>/dev/null || true)

            if echo "$result" | grep -q '/org/freedesktop/secrets/collection/Login'; then
              echo "Login collection already exists, skipping creation."
              exit 0
            fi

            # Create the Login collection with "default" alias
            # CreateCollection signature: (a{sv}, s) -> (o, o)
            $busctl --user call org.freedesktop.secrets \
              /org/freedesktop/secrets \
              org.freedesktop.Secret.Service CreateCollection "a{sv}s" \
              1 "org.freedesktop.Secret.Collection.Label" s "Login" \
              "default"

            echo "Created Login collection with default alias."
          '';
        in "${initScript}";
      };
    };

    # Provide libsecret so apps and secret-tool can talk to the
    # Secret Service via the standard C API.
    environment.systemPackages = [pkgs.libsecret];

    # Disable gnome-keyring by default to avoid conflicts.
    services.gnome.gnome-keyring.enable = lib.mkDefault false;
  };
}
