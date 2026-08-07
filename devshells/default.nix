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
    shellHook = ''
      export GIO_MODULE_DIR="${pkgs.glib-networking}/lib/gio/modules"
      export WEBKIT_DISABLE_COMPOSITING_MODE=1
      echo "GymNova · node $(node --version) · cargo $(cargo --version | cut -d' ' -f2)"
    '';
  };
}
