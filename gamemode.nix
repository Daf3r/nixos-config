{ config, pkgs, ... }:

# A toggle that drops the laptop panel to scale 1 for the duration of a game,
# and puts it back afterwards.
#
# The problem it solves is specific to a fractionally-scaled output. eDP runs at
# scale 1.6, so a fullscreen game is handed a 1600x900 logical surface that the
# compositor then has to scale up to the panel's real 2560x1440 on every frame.
# That rules out direct scanout — handing the game's own buffer straight to the
# display — and forces a composite pass per frame instead. CS2 opened fine and
# felt heavy for exactly this reason, not because anything was misconfigured.
#
# At scale 1 the surface matches the panel and the game's frames can go out
# untouched. Everything else on screen becomes tiny while it lasts, which does
# not matter when a fullscreen game is the only thing visible.
#
# VRR is switched from on-demand to always-on at the same time. On-demand only
# engages for windows matching the variable-refresh-rate rule, and the handover
# is one more thing that can go wrong mid-match.
#
# Deliberately a manual toggle rather than something automatic. Tying it to a
# window rule would mean the panel changing scale whenever a matching window
# appeared — including alt-tabbing to a browser between rounds.
let
  # Matched by EDID, not connector name: that name has already changed once
  # between boots on this machine (see ../gpu.nix).
  panel = "California Institute of Technology MNH301CA3-1 Unknown";

  game-mode = pkgs.writeShellApplication {
    name = "game-mode";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      panel="${panel}"
      state="''${XDG_RUNTIME_DIR:-/tmp}/game-mode.on"

      if [ -e "$state" ]; then
        niri msg output "$panel" scale 1.6
        niri msg output "$panel" vrr --on-demand on
        rm -f "$state"
        echo "game mode off — panel back to scale 1.6"
      else
        niri msg output "$panel" scale 1
        niri msg output "$panel" vrr on
        touch "$state"
        echo "game mode on — panel at scale 1, VRR always on"
      fi
    '';
  };
in
{
  home.packages = [ game-mode ];
}
