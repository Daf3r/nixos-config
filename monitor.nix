{ config, lib, pkgs, ... }:

# A always-on sampler that records what the machine was doing during a
# slowdown. The load spikes on this laptop come in episodes minutes apart, so
# watching top by hand never catches them: by the time a human notices the fans,
# the culprit has already finished. This service samples every three seconds and
# writes a snapshot only when CPU use, memory-stall pressure, or swap traffic
# crosses a threshold, which keeps the log small enough to read but complete
# enough to name the process responsible. Without it a slowdown leaves no
# evidence behind and the next diagnosis starts from zero again.

let
  sampler = pkgs.writeShellApplication {
    name = "perf-sampler";
    runtimeInputs = with pkgs; [ procps lm_sensors coreutils gawk gnugrep util-linux ];
    text = ''
      LOG="''${XDG_STATE_HOME:-$HOME/.local/state}/perf-sampler.log"
      mkdir -p "$(dirname "$LOG")"

      # Snapshot when any of these trip. The PSI thresholds matter more than the
      # CPU one: "some avg10" above 20 means tasks spent a fifth of the last ten
      # seconds blocked waiting for memory or IO, which is exactly the freeze
      # the user feels, and it can happen while CPU use looks unremarkable.
      CPU_PCT=70
      PSI_MEM=15
      PSI_IO=25

      prev_total=0; prev_idle=0

      while :; do
        read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
        total=$((user+nice+system+idle+iowait+irq+softirq+steal))
        idle_all=$((idle+iowait))

        cpu=0
        if [ "$prev_total" -ne 0 ]; then
          dt=$((total - prev_total)); di=$((idle_all - prev_idle))
          [ "$dt" -gt 0 ] && cpu=$(( (100 * (dt - di)) / dt ))
        fi
        prev_total=$total; prev_idle=$idle_all

        # PSI "some avg10" for memory and IO, as whole numbers.
        psi_mem=$(awk '/^some/{split($2,a,"=");printf "%d", a[2]}' /proc/pressure/memory)
        psi_io=$(awk '/^some/{split($2,a,"=");printf "%d", a[2]}' /proc/pressure/io)

        if [ "$cpu" -ge "$CPU_PCT" ] || [ "$psi_mem" -ge "$PSI_MEM" ] || [ "$psi_io" -ge "$PSI_IO" ]; then
          {
            echo "==== $(date -Is)  cpu=''${cpu}%  psi_mem=''${psi_mem}  psi_io=''${psi_io}  load=$(cut -d' ' -f1-3 /proc/loadavg)"
            # Cumulative stall counters: the delta between two snapshots shows
            # whether this episode involved blocking reclaim or compaction.
            grep -E '^(compact_stall|compact_fail|allocstall_movable|pgsteal_direct|pswpin|pswpout)' /proc/vmstat \
              | awk '{printf "%s=%s ", $1, $2} END {print ""}'
            echo "mem: $(free -m | awk '/^Mem:/{printf "used=%sM avail=%sM", $3, $7}')  swap: $(free -m | awk '/^Swap:/{printf "%s/%sM", $3, $2}')"
            echo "temp: $(sensors 2>/dev/null | awk '/^Tctl:|^edge:/{printf "%s%s ", $1, $2}')"
            ps -eo pid,pcpu,pmem,rss,comm --sort=-pcpu --no-headers | head -8 \
              | awk '{printf "  %-7s cpu=%-5s mem=%-4s rss=%6.0fMB  %s\n", $1, $2, $3, $4/1024, $5}'
          } >> "$LOG"
        fi
        sleep 3
      done
    '';
  };
in
{
  environment.systemPackages = [ sampler ];

  systemd.user.services.perf-sampler = {
    description = "Sample system state during load and memory-stall episodes";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      ExecStart = lib.getExe sampler;
      Restart = "always";
      RestartSec = 10;
      # The sampler must never become part of the problem it is measuring, so
      # it runs at the lowest CPU and IO priority available.
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };

  # Keep the log from growing without bound; a week of episodes is plenty to
  # spot a pattern and the file would otherwise outlive its usefulness.
  systemd.user.tmpfiles.rules = [
    "f %S/perf-sampler.log 0644 - - 7d"
  ];
}
