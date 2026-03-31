{
  description = "WM-agnostic Secret Service stack for NixOS (oo7-daemon + SSH agent)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # TODO: change to GitHub URL once published
    oo7-ssh-agent.url = "git+file:///home/kronberger/Programming/rust/oo7-ssh-agent";
    oo7-ssh-agent.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    self,
    nixpkgs,
    oo7-ssh-agent,
    ...
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    nixosModules = {
      daemon = import ./modules/daemon.nix;
      ssh-agent = import ./modules/ssh-agent.nix;
      portal = import ./modules/portal.nix;
      pam = import ./modules/pam.nix;

      # Convenience module that pulls in all components.
      default = {
        imports = [
          self.nixosModules.daemon
          self.nixosModules.ssh-agent
          self.nixosModules.portal
          self.nixosModules.pam
        ];
      };
    };

    packages.${system} = {
      oo7-ssh-agent = oo7-ssh-agent.packages.${system}.oo7-ssh-agent;
      oo7-pam = pkgs.callPackage ./pkgs/oo7-pam.nix {};
      default = self.packages.${system}.oo7-ssh-agent;
    };
  };
}
