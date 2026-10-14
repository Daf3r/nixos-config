{
  claude-desktop,
  fetchurl,
  pipewire,
}:

# Claude Desktop 2.37337.1, past the 2.9939.4 that the flake input pins.
#
# The flake (poeck/claude-desktop-nix-flake) has not been bumped since its
# pin, so this overrides only version and .deb hash, from the same Anthropic
# apt repo the flake reads. Its package expects the .deb to be unpacked by a
# fixed recipe; the one new requirement in this version is libpipewire, used
# by the native claude-native-binding.node. Without pipewire in buildInputs,
# auto-patchelf fails the build.
#
# Remove this file, and point home.nix back at the flake input, once the flake
# publishes a version >= 2.37337.1.
claude-desktop.overrideAttrs (o: {
  version = "2.37337.1";
  buildInputs = o.buildInputs ++ [ pipewire ];
  src = fetchurl {
    url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_2.37337.1_amd64.deb";
    hash = "sha256-QXRbCRTw/1FjGh/xu0A7g2v1yZWEXMpnQt05vKOi2hQ=";
  };
})
