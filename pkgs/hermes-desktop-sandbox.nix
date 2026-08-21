{
  lib,
  writeShellApplication,
  writeText,
  util-linux,
}:

# Hermes Desktop, launched without the sudo prompt its own launcher cannot
# satisfy from a menu icon.
#
# Every `hermes update` that touches the desktop app rebuilds it with
# electron-builder, which recreates apps/desktop/release/linux-unpacked/
# chrome-sandbox owned by the invoking user and mode 0755. Hermes'
# _desktop_linux_sandbox_fixup() insists on root:root 4755 and otherwise shells
# out to `sudo chown` and `sudo chmod`. Launched from the menu there is no TTY
# and no askpass, so sudo fails, the launcher calls sys.exit(1), and — with
# Terminal=false — clicking the icon does nothing at all. That is what happened
# here on 2026-08-21 after updating to v0.20.5.
#
# Upstream does have a fallback, but it cannot fire on this machine: it only
# drops to --no-sandbox when /proc/sys/kernel/apparmor_restrict_unprivileged_userns
# reads "1", a file that exists on Ubuntu 23.10+ and not on NixOS. Setting
# ELECTRON_DISABLE_SANDBOX=1 would force that same fallback, but it throws away
# Chromium's sandbox entirely on a host where the namespace sandbox works, so it
# pays in security for a problem that is only about file ownership.
#
# So this wrapper runs Hermes' own `desktop` command — same build, same content
# stamp, same Node PATH, same HERMES_DESKTOP_* environment, so nothing here has
# to be kept in step with upstream's launch logic — and patches exactly one
# function: the sandbox preflight returns success, without touching anything,
# when the helper is not SUID but unprivileged user namespaces are available.
# Chromium then uses its namespace sandbox and never looks at the SUID helper.
# In every other case the original function runs unchanged, including its sudo
# path when a real terminal is there to answer it.
#
# The probe has to be the nested one. Chromium's actual gate is
# Credentials::CanCreateProcessInNewUserNS(), which creates the namespace, writes
# uid_map/gid_map, drops capabilities and then tries a *second*, nested
# namespace. A plain `unshare --user` succeeds in cases where that sequence does
# not, and a false positive here is worse than no wrapper: the launcher would
# report success and Electron would abort looking for the SUID helper.

let
  unshare = lib.getExe' util-linux "unshare";

  launcher = writeText "hermes-desktop-launcher.py" ''
    """Run `hermes desktop` with the SUID-sandbox preflight relaxed.

    Installed by ~/nixos-config/pkgs/hermes-desktop-sandbox.nix; see that file
    for why this exists.
    """

    import os
    import stat
    import subprocess
    import sys
    from pathlib import Path

    UNSHARE = "${unshare}"

    # Only used by the HERMES_DESKTOP_SANDBOX_DEBUG report below. The launch path
    # never needs it: there the path arrives as the argument Hermes itself
    # computed, so the two cannot drift apart where it matters.
    RELEASE_SUBPATH = "apps/desktop/release/linux-unpacked/chrome-sandbox"


    def hermes_root() -> Path:
        """Locate the Hermes checkout the same way its own shims do."""
        override = os.environ.get("HERMES_HOME")
        base = Path(override).expanduser() if override else Path.home() / ".hermes"
        return base / "hermes-agent"


    def helper_is_suid_root(sandbox: Path) -> bool:
        """True when chrome-sandbox is already the root:root 4755 helper."""
        try:
            info = sandbox.lstat()
        except OSError:
            return False
        return (
            stat.S_ISREG(info.st_mode)
            and info.st_uid == 0
            and stat.S_IMODE(info.st_mode) == 0o4755
        )


    def userns_available() -> bool:
        """True when a nested unprivileged user namespace can be created."""
        try:
            completed = subprocess.run(
                [UNSHARE, "--user", "--map-root-user", UNSHARE, "--user", "true"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
                timeout=10,
            )
        except (OSError, subprocess.SubprocessError):
            return False
        return completed.returncode == 0


    def main() -> int:
        root = hermes_root()
        if not root.is_dir():
            print(f"✗ Hermes checkout not found at {root}", file=sys.stderr)
            return 1

        # Hermes' own entrypoint lives inside the checkout, so importing
        # hermes_cli works there by accident of sys.path[0]. This script runs
        # from the Nix store, so the checkout has to be added explicitly.
        sys.path.insert(0, str(root))

        if os.environ.get("HERMES_DESKTOP_SANDBOX_DEBUG") == "1":
            sandbox = root / RELEASE_SUBPATH
            print(f"chrome-sandbox: {sandbox}")
            print(f"  exists:       {sandbox.exists()}")
            print(f"  suid root:    {helper_is_suid_root(sandbox)}")
            print(f"  nested userns:{userns_available()}")
            print(
                "  decision:     "
                + (
                    "delegate to Hermes (helper already SUID root)"
                    if helper_is_suid_root(sandbox)
                    else "skip preflight, use namespace sandbox"
                    if userns_available()
                    else "delegate to Hermes (no usable namespace sandbox)"
                )
            )
            return 0

        try:
            import hermes_cli.main as hermes_main
        except ImportError as exc:
            print(f"✗ Cannot import Hermes CLI from {root}: {exc}", file=sys.stderr)
            return 1

        original = getattr(hermes_main, "_desktop_linux_sandbox_fixup", None)
        if original is None:
            # Upstream renamed or removed the preflight. Say so and launch
            # unpatched rather than guessing: a silent no-op here would look
            # exactly like the bug this wrapper exists to fix.
            print(
                "⚠ Hermes no longer exposes _desktop_linux_sandbox_fixup; "
                "launching unpatched. Revisit "
                "~/nixos-config/pkgs/hermes-desktop-sandbox.nix.",
                file=sys.stderr,
            )
        else:

            def patched(packaged_executable):
                sandbox = Path(packaged_executable).parent / "chrome-sandbox"
                if helper_is_suid_root(sandbox):
                    return original(packaged_executable)
                if userns_available():
                    return True
                return original(packaged_executable)

            hermes_main._desktop_linux_sandbox_fixup = patched

        sys.argv = ["hermes", "desktop", *sys.argv[1:]]
        hermes_main.main()
        return 0


    if __name__ == "__main__":
        sys.exit(main())
  '';
in
writeShellApplication {
  name = "hermes-desktop";
  meta = {
    description = "Hermes Desktop launcher that skips the SUID sandbox preflight";
    mainProgram = "hermes-desktop";
  };
  # PYTHONPATH and PYTHONHOME are cleared for the same reason Hermes' own shims
  # clear them: the venv is the only interpreter that has its dependencies, and
  # an inherited path from the calling shell makes the import fail in ways that
  # name neither Hermes nor Python.
  text = ''
    venv_python="''${HERMES_HOME:-$HOME/.hermes}/hermes-agent/venv/bin/python"
    if [ ! -x "$venv_python" ]; then
      echo "✗ Hermes venv interpreter not found: $venv_python" >&2
      exit 1
    fi
    unset PYTHONPATH PYTHONHOME
    exec "$venv_python" ${launcher} "$@"
  '';
}
