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

    # Claude Desktop. Not in nixpkgs. This flake repackages Anthropic's own
    # Linux beta from their Debian repository and refreshes the hash hourly via
    # CI — the alternatives extract and patch the macOS DMG instead, which is a
    # good deal more fragile.
    #
    # Its nixpkgs is deliberately not made to follow ours, same reasoning as
    # noctalia above: it is a repackaged binary, and pinning it to a different
    # nixpkgs than the one it was tested against buys nothing.
    claude-desktop.url = "github:poeck/claude-desktop-nix-flake";

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
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # Per-project development environments, entered automatically by direnv:
      # each project holds a one-line .envrc pointing here.
      #
      # They live in this flake rather than in the projects themselves for two
      # reasons. Nix requires flake files to be git-tracked, and gymnova belongs
      # to an organisation — putting a flake.nix there would either impose Nix on
      # the whole team or be impossible to use once excluded. And sharing this
      # flake's nixpkgs means one download and one set of versions instead of a
      # separate nixpkgs per project.
      devShells.${system} = import ./devshells { inherit pkgs; };

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
