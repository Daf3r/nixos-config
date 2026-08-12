{
  description = "daf3r's NixOS — niri + Noctalia v5";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";

    # Noctalia v5. Deliberately NOT following our nixpkgs: overriding any of
    # Noctalia's inputs changes the derivation hash and loses every hit on
    # noctalia.cachix.org. The `cachix` branch always points at the newest
    # commit that has already been built and pushed to that cache, so a rebuild
    # downloads instead of compiling.
    noctalia.url = "github:noctalia-dev/noctalia/cachix";

    # Claude Desktop. Not in nixpkgs. This flake repackages Anthropic's own
    # Linux beta from their Debian repository and refreshes the hash hourly via
    # CI — the alternatives extract and patch the macOS DMG instead, which is a
    # good deal more fragile.
    #
    # Its nixpkgs is deliberately not made to follow ours, same reasoning as
    # noctalia above: it is a repackaged binary, and pinning it to a different
    # nixpkgs than the one it was tested against buys nothing.
    claude-desktop.url = "github:poeck/claude-desktop-nix-flake";

    # ChatGPT Desktop — the official Linux x86_64 .deb published by OpenAI.
    # It is unpacked declaratively by ./pkgs/chatgpt-desktop.nix; no dpkg state
    # or imperative updater is used. The URL is a stable latest channel, so the
    # version and hash below are deliberately reviewed together when OpenAI
    # publishes a new build.

    # DankMaterialShell, under evaluation as a replacement for Noctalia — see
    # ./dms.nix for the reasoning and for how the two coexist on this branch.
    #
    # This one DOES follow our nixpkgs, unlike the three inputs above, and the
    # difference is not an oversight: those are pinned loose to keep binary
    # cache hits (noctalia.cachix.org) or because they are repackaged binaries.
    # DMS publishes no cache at all — its flake declares no substituters — so
    # there are no hits to lose, and following means one nixpkgs to download
    # instead of two. It is a Go binary plus QML, so a local build is cheap;
    # this is not the Electron situation the old ChatGPT repackager described.
    # Pinned to a release tag, NOT to a branch, and that is the point. The
    # default branch builds `1.6-beta`, so tracking it would buy exactly the
    # pre-release churn this migration was supposed to escape — Noctalia v5 is
    # beta too. v1.5.3 is the newest tagged release (2026-07-27).
    #
    # A tag never moves, so `nix flake update` cannot bump this: upgrading means
    # editing the version below by hand, on purpose, after reading the release
    # notes. Check for a newer one with
    #   gh release list -R AvengeMedia/DankMaterialShell -L 5
    #
    # Do not assume a steady release cadence when deciding how often to look:
    # v1.5.0 through v1.5.3 landed within three weeks, but v1.4.6 to v1.5.0 was
    # a two-month gap.
    dms = {
      url = "github:AvengeMedia/DankMaterialShell/v1.5.3";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # My own DMS plugins — today just claude-usage, wired up in ./dms.nix.
    #
    # `flake = false` because the repo ships no flake.nix: it is a source tree
    # of QML and JavaScript, not something that builds. The DMS module's
    # `plugins.<name>.src` takes it and links the subdirectory into
    # ~/.config/DankMaterialShell/plugins/.
    #
    # An input, and not the local path the plugin's own README first suggested,
    # because flakes evaluate in PURE mode: `src = /home/daf3r/Projects/...`
    # dies with "access to absolute path is forbidden in pure evaluation mode".
    # A `path:` input would have worked too, but it would tie this flake to a
    # directory that only exists on this machine.
    #
    # Unlike `dms` above this is NOT pinned to a tag — it is my own repo, and
    # `nix flake update dms-plugins` after a push is the intended loop. Note
    # that a change is not live until that update lands: editing the working
    # copy does nothing on its own once the plugin is declared here.
    dms-plugins = {
      url = "github:Daf3r/dms-plugins";
      flake = false;
    };

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
