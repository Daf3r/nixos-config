{ config, lib, pkgs, ... }:

# Memory reclaim tuning for a 30 GB machine that runs zram instead of a disk
# swap device. The kernel defaults assume a slow block device for swap and a
# much smaller machine, and on this laptop that mismatch showed up as multi
# second freezes: 14073 compact_stall events in under five hours of uptime, of
# which 11946 failed, plus 4.5M pages reclaimed synchronously (pgsteal_direct).
# A compact_stall is a process blocked inside the allocator while the kernel
# shuffles pages around, so every one of those failures is a stutter the user
# feels for nothing. Without this file the machine goes back to freezing under
# memory pressure even though 22 GB sit free.

{
  boot.kernel.sysctl = {
    # zram compresses at roughly 4.26x on this workload and lives in RAM, so
    # swapping to it costs a memcpy rather than a disk round trip. The default
    # of 10 (set by the xanmod kernel) tells the kernel to do almost anything
    # rather than swap, which pushes it into evicting page cache and into
    # synchronous reclaim instead. Leaving it low keeps zram nearly idle (1.3 GB
    # of 15 GB used) while processes stall waiting for memory.
    "vm.swappiness" = 150;

    # Swap readahead pulls in 2^page-cluster pages per fault. That amortises
    # seek latency on a disk, but zram has none, so the extra seven pages are
    # pure decompression work and wasted memory. Zero means read exactly the
    # page that faulted.
    "vm.page-cluster" = 0;

    # The reserve the allocator keeps for requests that cannot wait. 66 MB is
    # what the kernel picks by default for this much RAM, and it is far too thin
    # for a machine where the NVIDIA driver and btrfs both ask for higher order
    # allocations continuously. When the reserve runs dry the allocator falls
    # back to direct reclaim and direct compaction, which block the caller.
    # 256 MB is under 1% of RAM and buys the headroom those drivers need.
    "vm.min_free_kbytes" = 262144;

    # How far above the minimum watermark kswapd wakes up, in tenths of a
    # percent. At the default of 10 (0.1%, about 30 MB here) kswapd starts
    # reclaiming only once memory is already nearly exhausted, so allocations
    # overtake it and fall into direct reclaim — the 4.5M pgsteal_direct pages
    # and 17220 allocstall events. At 125 (1.25%) kswapd works in the background
    # ahead of demand, which is where reclaim belongs.
    "vm.watermark_scale_factor" = 125;

    # When the kernel sees external fragmentation it temporarily boosts the
    # watermarks by this factor (150% by default) and kicks off aggressive
    # reclaim plus compaction. On this machine that heuristic is the engine
    # behind the stalls: it fires constantly and fails 85% of the time, so it
    # burns CPU and blocks processes without producing the contiguous memory it
    # went looking for. Zero disables the boost; normal compaction still runs.
    "vm.watermark_boost_factor" = 0;
  };
}
