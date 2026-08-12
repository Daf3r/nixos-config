{
  lib,
  runCommand,
  makeBinaryWrapper,
  chatgpt-desktop,
}:

runCommand "chatgpt-desktop-keyring-${chatgpt-desktop.version}"
  {
    nativeBuildInputs = [ makeBinaryWrapper ];
    meta = chatgpt-desktop.meta // {
      mainProgram = "chatgpt";
    };
  }
  ''
    mkdir -p "$out/bin" "$out/share/applications" "$out/share/pixmaps"

    makeWrapper ${chatgpt-desktop}/bin/chatgpt "$out/bin/chatgpt" \
      --add-flags "--password-store=gnome-libsecret" \
      --add-flags "--force-device-scale-factor=1.25"

    for entry in ${chatgpt-desktop}/share/*; do
      name="$(basename "$entry")"
      [ "$name" = applications ] && continue
      ln -s "$entry" "$out/share/$name"
    done

    substitute ${chatgpt-desktop}/share/applications/chatgpt.desktop \
      "$out/share/applications/chatgpt.desktop" \
      --replace-fail '${chatgpt-desktop}/bin/chatgpt' "$out/bin/chatgpt"
  ''
