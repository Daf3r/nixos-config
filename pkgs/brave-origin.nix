{
  lib,
  stdenv,
  fetchurl,
  buildPackages,
  dpkg,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  adwaita-icon-theme,
  gsettings-desktop-schemas,
  gtk3,
  gtk4,
  qt6,
  libX11,
  libXScrnSaver,
  libXcomposite,
  libXcursor,
  libXdamage,
  libXext,
  libXfixes,
  libXi,
  libXrandr,
  libXrender,
  libXtst,
  libdrm,
  libkrb5,
  libuuid,
  libxkbcommon,
  libxshmfence,
  libgbm,
  nspr,
  nss,
  pango,
  pipewire,
  snappy,
  udev,
  wayland,
  xorg,
  zlib,
  libGL,
  libpulseaudio,
  libva,
  addDriverRunpath,

  commandLineArgs ? "",
  enableVideoAcceleration ? true,
  enableVulkan ? false,
}:

# Brave Origin is not in nixpkgs: it ships only through Brave's own apt/rpm
# repository, so we unpack the upstream .deb the same way pkgs/by-name/br/brave
# does. Bump `version` + `hash` together; both come from
# https://brave-browser-apt-release.s3.brave.com/dists/stable/main/binary-amd64/Packages
let
  version = "1.93.132";

  deps = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    gdk-pixbuf
    glib
    gtk3
    gtk4
    libdrm
    libX11
    libGL
    libxkbcommon
    libXScrnSaver
    libXcomposite
    libXcursor
    libXdamage
    libXext
    libXfixes
    libXi
    libXrandr
    libXrender
    libxshmfence
    libXtst
    libuuid
    libgbm
    nspr
    nss
    pango
    pipewire
    udev
    wayland
    xorg.libxcb
    zlib
    snappy
    libkrb5
    qt6.qtbase
    libpulseaudio
    libva
  ];

  rpath = lib.makeLibraryPath deps + ":" + lib.makeSearchPathOutput "lib" "lib64" deps;
  binpath = lib.makeBinPath deps;

  enableFeatures =
    lib.optionals enableVideoAcceleration [
      "VaapiVideoDecoder"
      "VaapiVideoEncoder"
    ]
    ++ lib.optional enableVulkan "Vulkan";

  disableFeatures = [
    "OutdatedBuildDetector" # disable automatic updates; Nix owns the version
  ]
  ++ lib.optionals enableVideoAcceleration [ "UseChromeOSDirectVideoDecoder" ];
in
stdenv.mkDerivation {
  pname = "brave-origin";
  inherit version;

  src = fetchurl {
    url = "https://brave-browser-apt-release.s3.brave.com/pool/main/b/brave-origin/brave-origin_${version}_amd64.deb";
    hash = "sha256-53pc7094Aay9iAhxGdhcXU8PltRAL01pmmb2ga0B6Cg=";
  };

  dontConfigure = true;
  dontBuild = true;
  dontPatchELF = true;

  nativeBuildInputs = [
    dpkg
    addDriverRunpath
    (buildPackages.wrapGAppsHook3.override { makeWrapper = buildPackages.makeShellWrapper; })
  ];

  buildInputs = [
    # needed for GSETTINGS_SCHEMAS_PATH
    glib
    gsettings-desktop-schemas
    gtk3
    gtk4
    # needed for XDG_ICON_DIRS
    adwaita-icon-theme
  ];

  # Unpacking is handled by dpkg's setup hook, which extracts into ./root via
  # `dpkg-deb --fsys-tarfile | tar` — `dpkg-deb -x` fails on this archive
  # because chrome-sandbox carries a setuid bit that tar cannot apply here.
  sourceRoot = "root";

  installPhase = ''
    runHook preInstall

    mkdir -p $out $out/bin
    cp -R usr/share $out
    cp -R opt/ $out/opt

    export BINARYWRAPPER=$out/opt/brave.com/brave-origin/brave-origin

    # Fix path to bash in $BINARYWRAPPER
    substituteInPlace $BINARYWRAPPER \
        --replace-fail /bin/bash ${stdenv.shell} \
        --replace-fail 'CHROME_WRAPPER' 'WRAPPER'

    ln -sf $BINARYWRAPPER $out/bin/brave-origin

    for exe in $out/opt/brave.com/brave-origin/{brave,chrome_crashpad_handler}; do
        patchelf \
            --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" \
            --set-rpath "${rpath}" $exe
    done

    # Fix paths baked into the shipped desktop/config files
    substituteInPlace $out/share/applications/{brave-origin,com.brave.Origin}.desktop \
        --replace-fail /usr/bin/brave-origin-stable $out/bin/brave-origin
    substituteInPlace $out/share/gnome-control-center/default-apps/brave-origin.xml \
        --replace-fail /opt/brave.com $out/opt/brave.com
    substituteInPlace $out/opt/brave.com/brave-origin/default-app-block \
        --replace-fail /opt/brave.com $out/opt/brave.com

    runHook postInstall
  '';

  preFixup = ''
    gappsWrapperArgs+=(
      --prefix LD_LIBRARY_PATH : ${rpath}
      --prefix PATH            : ${binpath}
      --suffix PATH            : ${lib.makeBinPath [ xorg.xrandr ]}
      --add-flags "--enable-features=${lib.concatStringsSep "," enableFeatures}"
      --add-flags "--disable-features=${lib.concatStringsSep "," disableFeatures}"
      ${lib.optionalString (commandLineArgs != "") "--add-flags ${lib.escapeShellArg commandLineArgs}"}
    )
  '';

  postFixup = ''
    # GPU acceleration needs the driver runpath on the main binary
    addDriverRunpath $out/opt/brave.com/brave-origin/brave
  '';

  meta = {
    description = "Minimalist, ad-free build of the Brave browser (free on Linux)";
    homepage = "https://brave.com/origin/";
    license = lib.licenses.mpl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "brave-origin";
  };
}
