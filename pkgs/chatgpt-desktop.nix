{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  binutils,
  cairo,
  cups,
  dbus,
  expat,
  gdk-pixbuf,
  glib,
  gtk3,
  libX11,
  libXcomposite,
  libXdamage,
  libXext,
  libXfixes,
  libXrandr,
  libxcb,
  libxkbcommon,
  libdrm,
  libgcc,
  gcc,
  libusb1,
  mesa,
  nspr,
  nss,
  pango,
  systemd,
  xz,
}:

stdenv.mkDerivation {
  pname = "chatgpt";
  version = "26.825.41651";

  src = fetchurl {
    url = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/latest/chatgpt_amd64.deb";
    hash = "sha256-IbIulcDEOj8RTz7TJpKr7cY49AV6CPmMmINuLT6aZx4=";
  };

  nativeBuildInputs = [
    autoPatchelfHook
    binutils
    xz
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    gdk-pixbuf
    glib
    gtk3
    libX11
    libXcomposite
    libXdamage
    libXext
    libXfixes
    libXrandr
    libxcb
    libxkbcommon
    libdrm
    libgcc
    gcc
    libusb1
    mesa
    nspr
    nss
    pango
    systemd
  ];

  autoPatchelfIgnoreMissingDeps = [
    "libc.musl-x86_64.so.1"
    "libQt5Core.so.5"
    "libQt5Gui.so.5"
    "libQt5Widgets.so.5"
    "libQt6Core.so.6"
    "libQt6Gui.so.6"
    "libQt6Widgets.so.6"
  ];

  unpackPhase = ''
    runHook preUnpack
    mkdir deb root
    cd deb
    ar x "$src"
    tar -xJf data.tar.xz -C ../root
    cd ..
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a root/usr/lib root/usr/share "$out/"
    mkdir -p "$out/bin"
    cp -a root/usr/bin/chatgpt "$out/bin/chatgpt"

    # The Debian launcher is relative, so it remains valid after moving the
    # tree into the Nix store. The desktop entry must point at that store path.
    substituteInPlace "$out/share/applications/chatgpt.desktop" \
      --replace-fail 'Exec=chatgpt %U' 'Exec=@out@/bin/chatgpt %U'
    substituteInPlace "$out/share/applications/chatgpt.desktop" \
      --replace-fail '@out@' "$out"
    runHook postInstall
  '';

  meta = {
    description = "ChatGPT Desktop by OpenAI";
    homepage = "https://developers.openai.com/codex/app";
    license = lib.licenses.unfree;
    mainProgram = "chatgpt";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
