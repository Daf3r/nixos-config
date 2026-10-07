{
  claude-desktop,
  fetchurl,
  pipewire,
}:

# Claude Desktop 2.26454.2, past the 2.9939.4 that the flake input pins.
#
# The flake (poeck/claude-desktop-nix-flake) has not been bumped since its
# pin, so this overrides only version and .deb hash, from the same Anthropic
# apt repo the flake reads. Its package expects the .deb to be unpacked by a
# fixed recipe; the one new requirement in this version is libpipewire, used
# by the native claude-native-binding.node. Without pipewire in buildInputs,
# auto-patchelf fails the build.
#
# Remove this file, and point home.nix back at the flake input, once the flake
# publishes a version >= 2.26454.2.
claude-desktop.overrideAttrs (o: {
  version = "2.26454.2";
  buildInputs = o.buildInputs ++ [ pipewire ];
  src = fetchurl {
    url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_2.26454.2_amd64.deb";
    hash = "sha256-slGgIkqGNYdPM1mN+O2JUrQn+EgV7llYDMAi1r2yQw8=";
  };
})
