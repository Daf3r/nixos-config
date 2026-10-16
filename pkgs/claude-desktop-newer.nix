{
  claude-desktop,
  fetchurl,
  pipewire,
}:

# Claude Desktop 2.42304.0, past the 2.9939.4 that the flake input pins.
#
# The flake (poeck/claude-desktop-nix-flake) has not been bumped since its
# pin, so this overrides only version and .deb hash, from the same Anthropic
# apt repo the flake reads. Its package expects the .deb to be unpacked by a
# fixed recipe; the one new requirement since 2.26454.2 is libpipewire, used
# by the native claude-native-binding.node. Without pipewire in buildInputs,
# auto-patchelf fails the build.
#
# updates/bump-claude-desktop.sh rewrites version and hash here, and it reads
# the version from the apt index, not from this file.
#
# Remove this file, and point home.nix back at the flake input, once the flake
# publishes a version >= the one above.
claude-desktop.overrideAttrs (o: rec {
  version = "2.42304.0";
  buildInputs = o.buildInputs ++ [ pipewire ];
  src = fetchurl {
    url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_${version}_amd64.deb";
    hash = "sha256-dM0szCnSQWUUTkVcvIcsbMKiSiY7g+c0IOlfiRZtSqQ=";
  };
})
