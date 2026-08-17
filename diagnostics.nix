{ config, lib, pkgs, ... }:

# A read-only deep snapshot of the machine, meant to be handed to someone (or
# something) that will read the whole thing and reason about it. The everyday
# tools answer one question each and lose the correlations that matter: a slow
# machine can be a degraded NVMe, a memory subsystem thrashing, a GPU driver
# falling back to software, or a compositor fighting Xwayland, and telling those
# apart needs all of them side by side with the same timestamp.
#
# Two rules keep this useful rather than merely thorough. Every command runs
# under a timeout, because a smartctl against a failing disk or an nvidia-smi
# against a wedged driver hangs forever and a diagnostic that dies halfway is
# worse than none. And every section is capped, because an untruncated dump runs
# to megabytes, and a report too large to read end to end gets skimmed, which
# defeats the point of collecting it.
#
# The script only reads. It changes no state anywhere.

let
  sysdiag = pkgs.writeShellApplication {
    name = "sysdiag";
    # Every probe is a single-quoted string handed to `bash -c`, so the shell
    # running this script must NOT expand it — that is the whole mechanism, not
    # an oversight, and SC2016 flags exactly that pattern.
    excludeShellChecks = [ "SC2016" ];
    runtimeInputs = with pkgs; [
      coreutils gawk gnugrep gnused util-linux procps
      pciutils usbutils lm_sensors smartmontools btrfs-progs nvme-cli
      dmidecode kmod iproute2 systemd wayland-utils
    ];
    text = ''
      # Land the report in the invoking user's state directory even under sudo,
      # so it stays readable and deletable without root afterwards.
      TARGET_USER="''${SUDO_USER:-$USER}"
      TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
      # Probes run through `bash -c`, which starts a fresh shell and inherits
      # only exported variables. Without this the sections that read files under
      # the user's home would silently expand to an empty path and report
      # nothing found, which reads identically to a genuinely clean result.
      export TARGET_HOME TARGET_USER
      OUT="$TARGET_HOME/.local/state/sysdiag-$(date +%Y%m%d-%H%M%S).txt"
      mkdir -p "$(dirname "$OUT")"
      : > "$OUT"

      IS_ROOT=no
      [ "$(id -u)" -eq 0 ] && IS_ROOT=yes

      # Run one command into one delimited, capped section. The delimiter is
      # greppable so a reader can jump between sections without scrolling.
      sec() {
        local title="$1" max="$2" cmd="$3"
        {
          echo
          echo "########## $title"
          local out rc=0
          out=$(timeout 20 bash -c "$cmd" 2>&1) || rc=$?
          if [ -n "$out" ]; then
            printf '%s\n' "$out" | head -n "$max"
            local total
            total=$(printf '%s\n' "$out" | wc -l)
            [ "$total" -gt "$max" ] && echo "[... truncado: $total lineas en total, mostradas $max ...]"
          else
            # An empty section must never be silent. Read as blank space it is
            # indistinguishable from "nothing wrong here", which is the reading
            # that hides problems rather than reporting them.
            if [ "$IS_ROOT" = no ]; then
              echo "[sysdiag] SIN SALIDA (posiblemente requiere root)"
            else
              echo "[sysdiag] SIN SALIDA"
            fi
          fi
          [ "$rc" -eq 124 ] && echo "[sysdiag] TIMEOUT tras 20s"
          [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && echo "[sysdiag] codigo de salida $rc"
        } >> "$OUT" 2>&1
        return 0
      }

      {
        echo "==================================================================="
        echo " sysdiag  --  $(date -Is)"
        echo " host=$(hostname)  usuario=$TARGET_USER  root=$IS_ROOT"
        echo " uptime: $(uptime -p 2>/dev/null || true)  desde $(uptime -s 2>/dev/null || true)"
        [ "$IS_ROOT" = no ] && echo " AVISO: sin root. dmesg, SMART y dmidecode saldran vacios o parciales."
        echo "==================================================================="
      } >> "$OUT"

      ##### Identidad del sistema
      sec "SISTEMA / NIXOS" 40 'nixos-version; echo; readlink -f /run/current-system; echo "booted: $(readlink -f /run/booted-system)"; echo; ls -l /nix/var/nix/profiles/system* 2>/dev/null | tail -8'
      sec "FIRMWARE / BIOS" 40 'dmidecode -t bios -t system -t baseboard 2>/dev/null | grep -vE "^#|^Handle|^$" | head -40'
      sec "KERNEL / CMDLINE" 20 'uname -a; echo; cat /proc/cmdline; echo; echo "taint=$(cat /proc/sys/kernel/tainted)"'
      sec "MODULOS CARGADOS" 60 'lsmod | head -60'

      ##### CPU, energia y temperatura
      sec "CPU" 45 'lscpu | grep -vE "^Flags|^Vulnerability" '
      sec "FRECUENCIAS Y GOBERNADOR" 30 'echo "driver: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null)"; echo "gobernador: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"; echo "amd_pstate: $(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null)"; echo "epp: $(cat /sys/devices/system/cpu/cpufreq/policy0/energy_performance_preference 2>/dev/null)"; echo "boost: $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null)"; echo; awk "/cpu MHz/{s+=\$4;n++} END{printf \"media=%.0f MHz sobre %d hilos\n\", s/n, n}" /proc/cpuinfo'
      sec "TEMPERATURAS Y VENTILADORES" 80 'sensors 2>/dev/null'
      sec "LIMITES DE POTENCIA (RAPL)" 30 'for d in /sys/class/powercap/*/; do [ -f "$d/name" ] || continue; lim=$(cat "$d/constraint_0_power_limit_uw" 2>/dev/null); erg=$(cat "$d/energy_uj" 2>/dev/null); echo "$(cat "$d/name"): limite=''${lim:-(no legible)} energia=''${erg:-(no legible)}"; done'
      sec "PERFIL DE PLATAFORMA" 15 'echo "actual: $(cat /sys/firmware/acpi/platform_profile 2>/dev/null)"; echo "opciones: $(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null)"; powerprofilesctl get 2>/dev/null'
      sec "BATERIA / ALIMENTACION" 25 'for p in /sys/class/power_supply/*/; do echo "== $(basename "$p")"; grep -H "" "$p"type "$p"status "$p"capacity 2>/dev/null | sed "s|.*/||"; done'

      ##### Memoria: el subsistema que causo las congelaciones
      sec "MEMORIA: RESUMEN" 20 'free -h; echo; swapon --show'
      sec "MEMORIA: SYSCTL DE RECLAIM" 20 'sysctl vm.swappiness vm.page-cluster vm.min_free_kbytes vm.watermark_scale_factor vm.watermark_boost_factor vm.vfs_cache_pressure vm.compaction_proactiveness 2>/dev/null'
      sec "MEMORIA: CONTADORES DE STALL" 30 'grep -E "^(compact_stall|compact_fail|compact_success|allocstall|pgsteal_direct|pgsteal_kswapd|pgscan_direct|pswpin|pswpout|thp_fault_fallback|thp_fault_alloc)" /proc/vmstat'
      sec "MEMORIA: PRESION PSI" 15 'for f in cpu memory io; do echo "== $f"; cat /proc/pressure/$f; done'
      sec "MEMORIA: ZRAM" 20 'echo "algoritmo: $(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"; awk "{printf \"original=%.2fGB comprimido=%.2fGB total=%.2fGB ratio=%.2fx\n\", \$1/1073741824, \$2/1073741824, \$3/1073741824, \$1/\$2}" /sys/block/zram0/mm_stat 2>/dev/null'
      sec "MEMORIA: FRAGMENTACION POR ZONA" 20 'cat /proc/buddyinfo'

      ##### Almacenamiento
      sec "DISCOS Y PARTICIONES" 40 'lsblk -o NAME,SIZE,MODEL,SERIAL,MOUNTPOINTS 2>/dev/null'
      sec "USO DE DISCO" 25 'df -h -x tmpfs -x devtmpfs'
      sec "BTRFS" 40 'for m in $(findmnt -t btrfs -no TARGET 2>/dev/null | sort -u); do echo "== $m"; btrfs filesystem usage "$m" 2>/dev/null | head -14; done'
      sec "BTRFS: ERRORES DE DISPOSITIVO" 25 'for m in $(findmnt -t btrfs -no TARGET 2>/dev/null | sort -u); do echo "== $m"; btrfs device stats "$m" 2>/dev/null; done'
      sec "SMART" 60 'for d in /dev/nvme?n1 /dev/sd?; do [ -e "$d" ] || continue; echo "===== $d"; smartctl -H -A "$d" 2>/dev/null | grep -vE "^smartctl|^Copyright|^$" | head -25; done'
      sec "IO: ESTADISTICAS" 25 'cat /proc/diskstats | awk "\$4+\$8 > 0 {print}" | head -20'

      ##### GPU: setup hibrido, donde mas cosas se rompen
      sec "GPU: DISPOSITIVOS PCI" 20 'lspci -nnk | grep -A3 -iE "vga|3d|display"'
      sec "GPU: NVIDIA" 45 'nvidia-smi 2>/dev/null | head -22; echo; nvidia-smi --query-gpu=name,driver_version,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit --format=csv 2>/dev/null'
      sec "GPU: NVIDIA, MEMORIA POR PROCESO" 30 'nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv 2>/dev/null; echo "-- graficos --"; nvidia-smi 2>/dev/null | sed -n "/Processes/,\$p" | head -25'
      sec "GPU: AMD" 25 'for c in /sys/class/drm/card*/device/; do [ -f "$c/power_dpm_state" ] || continue; echo "== $c"; echo "dpm: $(cat "$c/power_dpm_state" 2>/dev/null)"; echo "perf: $(cat "$c/power_dpm_force_performance_level" 2>/dev/null)"; done'
      sec "GPU: PARAMETROS DEL MODULO NVIDIA" 30 'for m in nvidia_drm nvidia nvidia_modeset; do [ -d "/sys/module/$m/parameters" ] || continue; echo "== $m"; for f in /sys/module/$m/parameters/*; do v=$(cat "$f" 2>/dev/null); echo "  $(basename "$f")=''${v:-(no legible)}"; done; done'

      ##### Graficos y sesion: el terreno del glitch de Discord
      sec "SESION GRAFICA" 25 'echo "XDG_SESSION_TYPE=''${XDG_SESSION_TYPE:-?}"; echo "WAYLAND_DISPLAY=''${WAYLAND_DISPLAY:-?}"; echo "XDG_CURRENT_DESKTOP=''${XDG_CURRENT_DESKTOP:-?}"; loginctl list-sessions --no-pager 2>/dev/null'
      sec "PROTOCOLOS WAYLAND" 60 'wayland-info 2>/dev/null | grep -E "interface:|name:" | head -60'
      sec "APPS ELECTRON Y SUS FLAGS" 40 'ps -eo pid,args | grep -iE "electron|discord|chatgpt|brave|code" | grep -v grep | sed "s/--/\n    --/g" | head -40'
      sec "CONFIG DE FLAGS DE ELECTRON" 30 'for f in "$TARGET_HOME"/.config/*-flags.conf "$TARGET_HOME"/.config/electron-flags.conf; do [ -f "$f" ] || continue; echo "== $f"; cat "$f"; done'
      sec "XWAYLAND" 20 'ps -eo pid,args | grep -i "[X]wayland" | head -5'

      ##### Procesos y servicios
      sec "TOP CPU" 25 'ps -eo pid,ppid,user,pcpu,pmem,rss,etimes,comm --sort=-pcpu | head -22'
      sec "TOP MEMORIA" 25 'ps -eo pid,user,pcpu,pmem,rss,comm --sort=-rss | head -22'
      sec "CONSUMO AGREGADO POR APP" 30 'ps -eo pcpu,rss,comm --no-headers | awk "{c[\$3]+=\$1; m[\$3]+=\$2; n[\$3]++} END {for (k in c) printf \"%-26s cpu=%5.1f%% rss=%6.0fMB procs=%d\n\", k, c[k], m[k]/1024, n[k]}" | sort -rn -k3 | head -25'
      sec "SERVICIOS FALLIDOS" 30 'systemctl --failed --no-pager; echo "-- usuario --"; systemctl --user --failed --no-pager 2>/dev/null'
      sec "ARRANQUE: UNIDADES LENTAS" 25 'systemd-analyze blame --no-pager 2>/dev/null | head -20; echo; systemd-analyze time 2>/dev/null'
      sec "TIMERS" 25 'systemctl list-timers --all --no-pager 2>/dev/null | head -20'

      ##### Red
      sec "RED: INTERFACES" 30 'ip -brief addr; echo; ip -brief link'
      sec "RED: RUTAS Y DNS" 25 'ip route | head -12; echo; resolvectl status 2>/dev/null | grep -E "DNS Server|Current DNS|Link " | head -15'

      ##### Journal, al final porque es lo mas ruidoso
      sec "JOURNAL: ERRORES DEDUPLICADOS" 60 'journalctl -p err -b --no-pager -o cat 2>/dev/null | sed -E "s/[0-9]{2,}/N/g" | sort | uniq -c | sort -rn | head -40'
      sec "JOURNAL: AVISOS DEDUPLICADOS" 40 'journalctl -p warning -b --no-pager -o cat 2>/dev/null | sed -E "s/[0-9]{2,}/N/g" | sort | uniq -c | sort -rn | head -30'
      sec "DMESG: ERRORES DEL KERNEL" 50 'dmesg -l err,crit,alert,emerg 2>/dev/null | tail -40'
      sec "DMESG: GPU Y GRAFICOS" 40 'dmesg 2>/dev/null | grep -iE "nvidia|amdgpu|drm|i915" | tail -30'
      sec "MUESTREADOR: EPISODIOS RECIENTES" 60 'tail -50 "$TARGET_HOME/.local/state/perf-sampler.log" 2>/dev/null || echo "(sin episodios registrados aun)"'

      {
        echo
        echo "########## FIN  $(date -Is)"
      } >> "$OUT"

      # Under sudo the file would otherwise belong to root, which makes it
      # awkward to read, share, or delete afterwards.
      if [ "$IS_ROOT" = yes ] && [ "$TARGET_USER" != root ]; then
        chown "$TARGET_USER" "$OUT"
      fi

      echo "Informe escrito en: $OUT"
      echo "Tamano: $(du -h "$OUT" | cut -f1), $(wc -l < "$OUT") lineas"
    '';
  };
in
{
  environment.systemPackages = [
    sysdiag

    # `lsof`. Missing the first time it was needed, on 2026-08-17, while checking
    # whether Proton had actually opened /dev/ntsync — the one question that no
    # log answers, because falling back to fsync is silent. The walk over
    # /proc/*/fd that replaced it works, but it is the sort of thing that gets
    # mistyped under pressure and then reads as "nothing has it open".
    pkgs.lsof
  ];
}
