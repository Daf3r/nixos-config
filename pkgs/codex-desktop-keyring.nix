{
  lib,
  runCommand,
  makeBinaryWrapper,
  codex-desktop,
}:

# ChatGPT Desktop, relaunched with an explicit credential backend.
#
# Same fix, same reason and same symptom as ./claude-desktop-keyring.nix: Electron
# picks its credential store by sniffing XDG_CURRENT_DESKTOP, recognises only
# GNOME, KDE, Unity and XFCE, and under niri falls back to the plaintext "basic"
# store — so every sign-in is lost on exit. Naming the backend is the whole fix.
#
# Verified rather than assumed here: the upstream launcher is a large shell
# script that parses its own arguments, and it does *not* handle --password-store
# itself. Its default case appends anything it does not recognise to ELECTRON_ARGS,
# which it execs Electron with, so a plain --add-flags reaches Electron untouched.
# It is documented as taking passthrough arguments after a `--` separator; that
# form works too, but it would swallow the %u below into the passthrough and break
# the codex:// scheme handler, so it is deliberately not used.
#
# Wrapping rather than overriding: the app comes from a flake input that converts
# OpenAI's macOS DMG into a Linux Electron app, and it exposes no argument for this.
# Its home-manager module has a cliPackage option but nothing for the keyring.
runCommand "codex-desktop-keyring-${codex-desktop.version}"
  {
    nativeBuildInputs = [ makeBinaryWrapper ];
    meta = codex-desktop.meta // {
      mainProgram = "codex-desktop";
    };
  }
  ''
    mkdir -p $out/bin $out/share/applications

    makeWrapper ${codex-desktop}/bin/codex-desktop $out/bin/codex-desktop \
      --add-flags "--password-store=gnome-libsecret"

    # Only the desktop entries hardcode the unwrapped binary, and they do it
    # twice — the main Exec plus the "New Window" action, which would otherwise
    # slip past the wrapper. The entry's other two actions call
    # /usr/bin/codex-update-manager, which does not exist here and is left alone:
    # an in-place updater has nothing to do with a read-only store path.
    for entry in ${codex-desktop}/share/*; do
      name="$(basename "$entry")"
      [ "$name" = applications ] && continue
      ln -s "$entry" "$out/share/$name"
    done

    substitute \
      ${codex-desktop}/share/applications/codex-desktop.desktop \
      $out/share/applications/codex-desktop.desktop \
      --replace-fail \
        "${codex-desktop}/bin/codex-desktop" \
        "$out/bin/codex-desktop"
  ''
