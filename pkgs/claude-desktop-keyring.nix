{
  lib,
  runCommand,
  makeBinaryWrapper,
  claude-desktop,
}:

# Claude Desktop, relaunched with an explicit credential backend.
#
# Without it the app reports that the sign-in will not be saved and asks you to
# install and unlock a system keyring — while the keyring is right there, running
# and unlocked. Electron picks its backend by sniffing XDG_CURRENT_DESKTOP and
# only recognises GNOME, KDE, Unity and XFCE; under niri it matches nothing and
# falls back to the "basic" store, which is plaintext and reported as no keyring
# at all. gnome-keyring-daemon already owns org.freedesktop.secrets here and the
# login collection is unlocked and the default one, so the only missing piece is
# naming the backend. libsecret is already on the wrapped binary's
# LD_LIBRARY_PATH, so nothing else has to be added.
#
# Same fix as the --password-store flag in ./t3code-app.nix, for the same reason.
# Any other Electron app installed here will need it too.
#
# Wrapping rather than overriding: the app comes from a flake input that
# repackages Anthropic's Debian build, and it exposes no argument for this.
runCommand "claude-desktop-keyring-${claude-desktop.version}"
  {
    nativeBuildInputs = [ makeBinaryWrapper ];
    meta = claude-desktop.meta // {
      mainProgram = "claude-desktop";
    };
  }
  ''
    mkdir -p $out/bin $out/share/applications

    makeWrapper ${claude-desktop}/bin/claude-desktop $out/bin/claude-desktop \
      --add-flags "--password-store=gnome-libsecret"

    # Everything except the desktop entries is fine as-is; only they hardcode the
    # unwrapped binary, and they do it three times — the main Exec plus the "New
    # chat" and "New code" actions, which would otherwise slip past the wrapper.
    for entry in ${claude-desktop}/share/*; do
      name="$(basename "$entry")"
      [ "$name" = applications ] && continue
      ln -s "$entry" "$out/share/$name"
    done

    substitute \
      ${claude-desktop}/share/applications/claude-desktop.desktop \
      $out/share/applications/claude-desktop.desktop \
      --replace-fail \
        "${claude-desktop}/bin/claude-desktop" \
        "$out/bin/claude-desktop"
  ''
