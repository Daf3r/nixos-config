{ ... }:

# Stop writing crash dumps to disk. On this machine a crashing Electron renderer
# (claude-desktop, 5 GB resident) made systemd-coredump read the whole process
# and write a compressed core of several hundred MB to btrfs while the app was
# frozen. The disk sat at 40 % IO pressure for minutes, and every other app
# stalled behind it. The crash itself still reaches the journal, so the event
# stays visible with `coredumpctl list` and `journalctl`; only the core file is
# dropped. Without this file the next renderer crash writes another multi-GB
# dump and the desktop freezes again.

{
  systemd.coredump.settings.Coredump.Storage = "none";
}
