{ config, lib, pkgs, ... }:

# fastfetch runs on every interactive fish start (see ./fish.nix), so it is the
# most-seen output on this machine after the prompt itself. Noctalia's community
# `fastfetch` template colours it from the active palette — but it needs two
# things that were both missing, and fails in a misleading way without them.
#
# 1. jq. The template's apply.sh merges themes/noctalia.jsonc into config.jsonc
#    with jq and never declares the dependency. Its first use is
#    `if ! jq empty "$config_file"`, so with jq absent the command-not-found is
#    swallowed by 2>/dev/null and the script reports "could not be parsed as
#    strict JSON" about a file that is perfectly valid.
#
# 2. config.jsonc itself. apply.sh refuses to create one:
#      Error: fastfetch config not found ... run fastfetch once to generate a
#      default config first
#    and fastfetch 2.56.0 has no include mechanism (-c loads exactly one file),
#    so merging into the real config is the only way a theme can apply.
#
# config.jsonc is therefore left MUTABLE rather than managed as a store symlink.
# That is deliberate: apply.sh rewrites it in place on every palette change, and
# the read-only symlink a home-manager-managed file would produce is exactly the
# collision documented in ./kitty.nix and ../gtk.nix. Here there is no include
# line to pre-empt, because there is nothing to include — so the file is seeded
# once and then belongs to Noctalia.
{
  home.packages = [ pkgs.jq ];

  # Runs only when the file is absent, so it seeds a fresh machine and then
  # never touches Noctalia's merged colours again. `fastfetch --gen-config`
  # emits strict JSON with no comments, which is what apply.sh requires — the
  # .jsonc extension notwithstanding.
  home.activation.fastfetchSeedConfig =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      fastfetchConfig="${config.xdg.configHome}/fastfetch/config.jsonc"
      if [ ! -e "$fastfetchConfig" ]; then
        run mkdir -p "$(dirname "$fastfetchConfig")"
        run ${pkgs.fastfetch}/bin/fastfetch --gen-config "$fastfetchConfig"
      fi
    '';
}
