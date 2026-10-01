{
  lib,
  path,
  runCommand,
  callPackage,
  commandLineArgs ? "",
}:

# Discord, built by nixpkgs' own package but pinned to the release in
# ./discord-sources.json instead of the one nixpkgs happens to carry.
#
# Discord will not run a host older than what its servers want, and nixpkgs
# trails upstream by days, so the packaged client kept asking to be updated
# (1.0.158 running with 1.0.160 published, 2026-10-01). Everything about how the
# package is built -- the FHS environment, the native modules staged into the
# config directory, the update-blocking settings -- is still nixpkgs' and keeps
# following it; the only thing replaced is the file naming which release to
# fetch. `upd` rewrites that file (updates/bump-discord.sh) from Discord's own
# manifest, which is also where nixpkgs' update script reads it.
#
# This is import-from-derivation on purpose. nixpkgs' package.nix reads
# `./sources.json` relative to itself and offers no argument to point it
# elsewhere, so the only way to reuse it unchanged is to hand it a copy of its
# own directory with that one file swapped. The alternative, vendoring
# package.nix, linux.nix and metadata.nix here, would freeze three hundred lines
# of someone else's code and stop following nixpkgs' fixes to them.
#
# It fails loudly rather than quietly if nixpkgs moves the package: the `cp`
# below has no fallback, so a rename or removal of by-name/di/discord stops the
# build and `upd` reports build_failed, with the reason in its log.
let
  upstream = "${path}/pkgs/by-name/di/discord";

  # Only the file that differs is swapped. Copying the whole directory keeps the
  # relative reads package.nix does (linux.nix, metadata.nix, the python helper)
  # working without naming any of them here.
  pinned = runCommand "discord-pinned-sources" { } ''
    cp -r ${upstream} $out
    chmod -R u+w $out
    cp ${./discord-sources.json} $out/sources.json
  '';
in
callPackage "${pinned}/package.nix" { inherit commandLineArgs; }
