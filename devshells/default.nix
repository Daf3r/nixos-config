{ pkgs }:

# Development environments for ~/Projects, one per project, entered
# automatically by direnv — each project holds a one-line `.envrc`:
#
#   use flake ~/nixos-config#remesafam
#
# Kept here rather than inside the projects because Nix requires flake files to
# be git-tracked, and gymnova belongs to an organisation: a flake.nix committed
# there would impose Nix on everyone, and one excluded from git could not be
# evaluated at all. Living here also means both shells share this flake's
# nixpkgs — one download, one set of versions, consistent with the system.
#
# The point of doing this per project rather than globally: RemesaFam uses pnpm
# and gymnova uses npm, and only gymnova needs Rust. Installing the union
# globally would put a 1.5 GB Rust toolchain on the PATH while working on a
# Next.js app, and make it easy to run the wrong package manager in the wrong
# repo and rewrite a lockfile.
let
  # Shared by both: every native Node addon here (better-sqlite3 under Prisma,
  # and Drizzle's driver) builds through node-gyp, which needs a compiler,
  # python and make at install time — not just to run.
  nodeNativeBuild = with pkgs; [
    python3
    gnumake
    gcc
    pkg-config
  ];

  # The Chromium that Playwright downloads into ~/.cache/ms-playwright is an
  # ordinary Linux binary, so it runs here only through nix-ld — and nix-ld
  # resolves nothing beyond glibc and the few libraries in its own profile.
  # Chromium needs twenty-two more. Note that gymnova already pulls gtk3, cairo,
  # pango and atk below: those are for Tauri, which finds them through
  # pkg-config at *build* time. A downloaded binary looks them up by soname at
  # *run* time instead, which is a different mechanism and a different path.
  #
  # Omitting these does not degrade anything gracefully — `chromium.launch()`
  # dies with "error while loading shared libraries: libglib-2.0.so.0", which
  # reads like a broken Playwright install rather than a missing system library.
  chromiumRuntime = with pkgs; [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    cairo
    cups
    dbus
    expat
    glib
    libgbm
    libxkbcommon
    nspr
    nss
    pango
    systemd # libudev.so.1
    xorg.libX11
    xorg.libXcomposite
    xorg.libXdamage
    xorg.libXext
    xorg.libXfixes
    xorg.libXrandr
    libxcb
  ];
in
{
  # Next.js 16 + React 19 + Drizzle, packaged for Android with Capacitor.
  remesafam = pkgs.mkShell {
    packages =
      with pkgs;
      [
        nodejs_22

        # pnpm, not npm: this repo has a pnpm-lock.yaml, and npm would resolve a
        # different tree and leave a competing package-lock.json behind.
        pnpm

        sqlite
      ]
      ++ nodeNativeBuild;

    shellHook = ''
      echo "RemesaFam · node $(node --version) · pnpm $(pnpm --version)"
    '';
  };

  # React + Vite front end, Fastify + Prisma sidecar, shipped as a desktop app
  # by Tauri 2.
  gymnova = pkgs.mkShell {
    packages =
      with pkgs;
      [
        # npm here, unlike RemesaFam: this repo has a package-lock.json.
        nodejs_22

        rustc
        cargo
        rust-analyzer

        sqlite

        # `npm run pack:context` builds the UI context pack (~130 screenshots
        # plus docs) by shelling out to `zip`. Not in the system profile, and
        # its absence only surfaces at the very last step of a long capture run.
        zip

        # Tauri 2 links against the host webkit stack through pkg-config. Without
        # these, `cargo build` fails inside the wry/webkit2gtk crates rather than
        # anywhere that points at the real cause. 4.1 specifically — Tauri 2
        # dropped the 4.0 series.
        webkitgtk_4_1
        gtk3
        libsoup_3
        librsvg
        cairo
        pango
        gdk-pixbuf
        atk
        openssl
      ]
      ++ nodeNativeBuild;

    # glib-networking provides the TLS backend webkit loads at *runtime*.
    # Without it the embedded browser fails every https:// request while the
    # build and everything else look perfectly fine.
    # LD_LIBRARY_PATH is what nix-ld hands to a foreign binary, and it is the
    # only way to reach Playwright's Chromium — every library below comes from
    # this same nixpkgs, so exporting it shell-wide cannot mix ABIs with the
    # Nix-built tools on the PATH.
    #
    # PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD keeps `npm ci` from re-fetching ~150 MB
    # of browsers that are already in ~/.cache/ms-playwright.
    shellHook = ''
      export GIO_MODULE_DIR="${pkgs.glib-networking}/lib/gio/modules"
      export WEBKIT_DISABLE_COMPOSITING_MODE=1
      export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath chromiumRuntime}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
      export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
      echo "GymNova · node $(node --version) · cargo $(cargo --version | cut -d' ' -f2)"
    '';
  };

  # My own Noctalia plugins. They are written in Luau, which is not a language
  # whose toolchain deserves a place in the system profile: it is needed only
  # here, to run the logic.luau suite without bringing up the graphical shell.
  noctalia-plugins = pkgs.mkShell {
    packages = with pkgs; [
      luau # interpreter, plus luau-analyze and luau-compile

      # luau-analyze cannot be told about host-injected globals — that is a
      # luau-lsp feature. Without it, service.luau, widget.luau and panel.luau
      # are unverifiable outside the running shell, because every noctalia.*
      # and ui.* call reads as an unknown global. With Noctalia's own
      # noctalia.d.luau passed as --definitions, they typecheck offline.
      luau-lsp

      fish # the test runner is fish, like the rest of the project

      # The suite has to feed real JSON fixtures to logic.luau, and Luau parses
      # no JSON — the plugin gets that from the host, which is absent here. The
      # runner converts the fixtures to a Luau module first, and that converter
      # is python. Declared rather than inherited from the user profile so the
      # suite does not depend on what happens to be on PATH.
      python3
    ];

    # `luau` the REPL has no --version flag, so the version comes from Nix at
    # evaluation time rather than from the binary.
    shellHook = ''
      echo "noctalia-plugins · luau ${pkgs.luau.version}"
    '';
  };
}
