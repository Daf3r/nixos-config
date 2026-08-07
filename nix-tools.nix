{ config, pkgs, ... }:

# Tooling for the thing this machine is actually used for: working on its own
# NixOS config. None of it was installed, which meant every rebuild today was
# run blind — no progress, no indication of what a switch was about to change,
# and no way to try a package without committing it to the config first.
{
  home.packages = with pkgs; [
    # `, cowsay hello` runs a program straight from nixpkgs without installing
    # it. The point is to stop reaching for home.packages every time something
    # is needed once — the vast majority of "let me just try this" cases.
    comma

    # Turns nix's wall of store paths into a live tree of what is building,
    # downloading and waiting. nh already uses it internally; this makes it
    # available to plain `nix build` too, as `nom build`.
    nix-output-monitor

    # Reads a store path and shows why it is there — which dependency pulled it
    # in. The tool to reach for when the closure grows and it is not obvious
    # what added 400 MB.
    nix-tree
  ];

  # Per-project development environments that activate on `cd` and deactivate on
  # the way out. This is the NixOS development workflow, and its absence is why
  # `nodejs` and `gcc` are currently installed globally in ./home.nix: with
  # direnv they belong in a per-project flake.nix or shell.nix instead, and stop
  # existing on this machine the moment you leave the directory.
  #
  # Usage: drop a `use flake` (or `use nix`) line in a project's .envrc, run
  # `direnv allow` once, and that is the whole setup.
  programs.direnv = {
    enable = true;

    # enableFishIntegration is deliberately absent: home-manager marks it
    # read-only and sets it to true itself, so assigning it — even to true —
    # fails the build with "read-only, but it's set multiple times".

    # Caches the evaluated environment, so re-entering a project is instant
    # rather than a fresh nix evaluation, and keeps the shell's store paths
    # alive against garbage collection.
    nix-direnv.enable = true;
  };
}
