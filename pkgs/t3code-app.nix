{
  lib,
  appimageTools,
  fetchurl,
  makeWrapper,
}:

# The T3 Code desktop app. Upstream ships Linux only as an AppImage — no .deb,
# no npm equivalent of the Electron shell — so it gets the standard FHS wrapper
# rather than being unpacked like ./brave-origin.nix.
#
# Bump `version` + `hash` together from
# https://github.com/pingdotgg/t3code/releases:
#   nix store prefetch-file https://github.com/pingdotgg/t3code/releases/download/v<version>/T3-Code-<version>-x86_64.AppImage
let
  pname = "t3code";
  version = "0.0.32";

  src = fetchurl {
    url = "https://github.com/pingdotgg/t3code/releases/download/v${version}/T3-Code-${version}-x86_64.AppImage";
    hash = "sha256-SS7ctI7vlzCfNMS3CoEhuGfDronCBowuKLs5Oo2CLCI=";
  };

  contents = appimageTools.extract { inherit pname version src; };
in
appimageTools.wrapType2 {
  inherit pname version src;

  nativeBuildInputs = [ makeWrapper ];

  extraInstallCommands = ''
    # --password-store is the whole reason this is not a bare wrapType2.
    #
    # Electron picks its credential backend by sniffing XDG_CURRENT_DESKTOP, and
    # it only recognises GNOME, KDE, Unity and XFCE. Here that variable says
    # "niri", so Chromium falls back to the "basic" store — plaintext, treated as
    # "no keyring available" — and the app reports that the sign-in will not be
    # saved. The Secret Service itself is fine: gnome-keyring-daemon owns
    # org.freedesktop.secrets and the login collection is unlocked and default;
    # nothing was ever going to find it without being told which backend to use.
    #
    # This is very likely the same failure that made the Clerk sign-in look
    # broken under Hyprland on the old install — another compositor Electron does
    # not recognise — where the modal kept returning to "You are signed out"
    # while the CLI held a perfectly valid stored credential.
    wrapProgram $out/bin/${pname} \
      --add-flags "--password-store=gnome-libsecret"

    install -Dm444 ${contents}/${pname}.desktop -t $out/share/applications

    # The AppImage's own entry runs `AppRun --no-sandbox`. The path has to point
    # at the wrapper, and dropping --no-sandbox lets Electron use the user
    # namespace sandbox, which works here — the setuid chrome-sandbox helper is
    # the thing that cannot work from the store, not the sandbox itself.
    substituteInPlace $out/share/applications/${pname}.desktop \
      --replace-fail 'Exec=AppRun --no-sandbox %U' "Exec=$out/bin/${pname} %U"

    cp -r ${contents}/usr/share/icons $out/share/
  '';

  meta = {
    description = "T3 Code desktop app";
    homepage = "https://github.com/pingdotgg/t3code";
    license = lib.licenses.mit;
    mainProgram = pname;
    platforms = [ "x86_64-linux" ];
  };
}
