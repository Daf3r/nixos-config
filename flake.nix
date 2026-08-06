{
  description = "daf3r's NixOS — Hyprland + Noctalia v5";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";

    # Noctalia v5. Deliberately NOT following our nixpkgs: overriding any of
    # Noctalia's inputs changes the derivation hash and loses every hit on
    # noctalia.cachix.org. The `cachix` branch always points at the newest
    # commit that has already been built and pushed to that cache, so a rebuild
    # downloads instead of compiling.
    noctalia.url = "github:noctalia-dev/noctalia/cachix";

    zen-browser.url = "github:youwen5/zen-browser-flake";
    zen-browser.inputs.nixpkgs.follows = "nixpkgs";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      home-manager,
      ...
    }:
    {
      # Named after networking.hostName so `nixos-rebuild switch --flake .`
      # resolves it without spelling out the attribute.
      nixosConfigurations.daf3r-starter = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";

        specialArgs = { inherit inputs; };
        modules = [
          ./configuration.nix

          home-manager.nixosModules.home-manager
          {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              extraSpecialArgs = { inherit inputs; };
              users.daf3r = import ./home.nix;
              backupFileExtension = "backup";
            };
          }
        ];
      };
    };
}
