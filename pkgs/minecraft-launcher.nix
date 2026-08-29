{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  copyDesktopItems,
  makeDesktopItem,
  alsa-lib,
  atk,
  cairo,
  cups,
  curl,
  dbus,
  expat,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  gtk3,
  libdrm,
  libgbm,
  libglvnd,
  libpulseaudio,
  libsecret,
  libuuid,
  libX11,
  libxcb,
  libXcomposite,
  libXcursor,
  libXdamage,
  libXext,
  libXfixes,
  libXi,
  libXrandr,
  libXrender,
  libXScrnSaver,
  libXtst,
  mesa,
  nspr,
  nss,
  pango,
  systemd,
  zlib,
}:
let
  desktopItem = makeDesktopItem {
    name = "minecraft-launcher";
    exec = "minecraft-launcher";
    icon = "minecraft-launcher";
    comment = "Official launcher for Minecraft";
    desktopName = "Minecraft Launcher";
    categories = [ "Game" ];
  };

  runtimeLibraries = [
    alsa-lib
    atk
    cairo
    cups
    curl
    dbus
    expat
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk3
    libdrm
    libgbm
    libglvnd
    libpulseaudio
    libsecret
    libuuid
    libX11
    libxcb
    libXcomposite
    libXcursor
    libXdamage
    libXext
    libXfixes
    libXi
    libXrandr
    libXrender
    libXScrnSaver
    libXtst
    mesa
    nspr
    nss
    pango
    stdenv.cc.cc.lib
    systemd
    zlib
  ];
in
stdenv.mkDerivation {
  pname = "minecraft-launcher";
  version = "2.2.2141";

  # This is Mojang's "Other distributions" download. It is a small bootstrap
  # that keeps the actual launcher core current in ~/.minecraft/launcher.
  src = fetchurl {
    url = "https://launcher.mojang.com/download/Minecraft.tar.gz";
    hash = "sha256-aVJpKBVHu7z0f+dGMwJ6Dk3cE6YQYMaGpyF+hdMU5F4=";
  };

  icon = fetchurl {
    url = "https://launcher.mojang.com/download/minecraft-launcher.svg";
    hash = "sha256-NcK8rrCfpLiGTpQi/Wa/YIR3Bvi0QA7EpmumQ2sQH3E=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    copyDesktopItems
    makeWrapper
  ];

  buildInputs = runtimeLibraries;

  sourceRoot = "minecraft-launcher";
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 minecraft-launcher $out/libexec/minecraft-launcher
    install -Dm644 $icon $out/share/icons/hicolor/scalable/apps/minecraft-launcher.svg

    # The bootstrap downloads Mojang's launcher core, Java and game natives
    # after installation. Keep the NixOS runtime visible to those children;
    # programs.nix-ld handles the interpreter of their unpatched ELF binaries.
    makeWrapper $out/libexec/minecraft-launcher $out/bin/minecraft-launcher \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath runtimeLibraries} \
      --chdir /tmp

    runHook postInstall
  '';

  desktopItems = [ desktopItem ];

  meta = {
    description = "Official launcher for Minecraft, packaged for NixOS";
    homepage = "https://www.minecraft.net/en-us/download";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "minecraft-launcher";
  };
}
