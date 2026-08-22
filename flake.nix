{
  description = "daf3r's NixOS — niri + DankMaterialShell";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";

    # Claude Desktop. Not in nixpkgs. This flake repackages Anthropic's own
    # Linux beta from their Debian repository and refreshes the hash hourly via
    # CI — the alternatives extract and patch the macOS DMG instead, which is a
    # good deal more fragile.
    #
    # Its nixpkgs is deliberately not made to follow ours: it is a repackaged
    # binary, and pinning it to a different nixpkgs than the one it was tested
    # against buys nothing.
    claude-desktop.url = "github:poeck/claude-desktop-nix-flake";

    # ChatGPT Desktop — the official Linux x86_64 .deb published by OpenAI.
    # It is unpacked declaratively by ./pkgs/chatgpt-desktop.nix; no dpkg state
    # or imperative updater is used. The URL is a stable latest channel, so the
    # version and hash below are deliberately reviewed together when OpenAI
    # publishes a new build.

    # DankMaterialShell, the session shell since 2026-08-10 — see ./dms.nix.
    #
    # This one DOES follow our nixpkgs, unlike claude-desktop above, and the
    # difference is not an oversight: that one is pinned loose because it is a
    # repackaged binary. DMS publishes no cache at all — its flake declares no
    # substituters — so there are no hits to lose, and following means one
    # nixpkgs to download instead of two. It is a Go binary plus QML, so a local
    # build is cheap; this is not the Electron situation the old ChatGPT
    # repackager described.
    # Pinned to a release tag, NOT to a branch, and that is the point. The
    # default branch builds `1.6-beta`, so tracking it would buy exactly the
    # pre-release churn this migration was supposed to escape — the old shell,
    # Noctalia v5, was beta too. v1.5.3 is the newest tagged release (2026-07-27).
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

          # One `dms` binary for the whole system, and this is what guarantees
          # it. nixpkgs ALSO packages dms-shell, at its own version, so a bare
          # `pkgs.dms-shell` in a wrapper script silently resolves to a second
          # copy: 115 MiB of closure, and scripts talking to a different binary
          # than the shell that is actually running. Both happened to be 1.5.3
          # when this was written, which is exactly why it went unnoticed.
          #
          # With this overlay `pkgs.dms-shell` IS the pinned input everywhere,
          # including inside home-manager, which reads the system pkgs because
          # useGlobalPkgs is set below. The check that catches a regression:
          #
          #   nix path-info -r /run/current-system | grep dms-shell
          #
          # must name exactly one store path (plus its fish completions).
          {
            nixpkgs.overlays = [
              (_final: prev: {
                dms-shell = inputs.dms.packages.${prev.stdenv.hostPlatform.system}.dms-shell;
              })
            ];
          }

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
