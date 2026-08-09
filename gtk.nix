{ config, pkgs, ... }:

# Cursor and GTK appearance.
#
# Both were left in a broken state by the Plasma 6 removal. ~/.config/gtk-3.0/
# settings.ini survived that migration and still pointed at `breeze_cursors`
# and the `breeze` icon theme, neither of which is installed any more — so GTK
# apps were asking for a cursor and icon set that do not exist and silently
# falling back. Nothing declared a cursor theme at all, which is why the
# compositor was drawing its built-in default arrow.
#
# Division of labour with Noctalia, same shape as ./terminal/kitty.nix:
#   Noctalia owns  gtk-{3.0,4.0}/noctalia.css  (the generated palette)
#   this file owns settings.ini and gtk.css    (cursor, icons, font, imports)
#
# gtk.css needs care. Setting gtk.theme makes home-manager write
# gtk-4.0/gtk.css itself — GTK4 ignores gtk-theme-name, so the theme has to be
# pulled in as CSS — and that file is a read-only store symlink. Noctalia's
# templates/gtk/apply.sh reacts to exactly that by deleting the symlink and
# writing a local file with its own import appended. Left alone the two would
# oscillate: every templates-apply replaces home-manager's symlink, and every
# rebuild restores it and drops the palette import until the next apply.
#
# The gtk3/gtk4 extraCss below settles it. apply.sh starts with
#
#   if [[ "$content" == *"noctalia.css"* ]] && [[ "$content" == *"@import"* ]]
#   then return 0
#
# so once home-manager's own gtk.css already carries the import, the script
# returns without touching the file. Same trick as the `include` line in
# ./terminal/kitty.nix. The import string has to keep matching that test.
{
  # Sets XCURSOR_THEME/SIZE for X11 and gtk.cursorTheme for GTK. Those land in
  # home.sessionVariables, which SDDM does not source — it execs the session
  # directly rather than through a login shell — so config/niri/config.kdl
  # repeats XCURSOR_THEME/SIZE in its own `environment` block; keep the theme
  # and size here and there in step.
  #
  # hyprcursor.enable was dropped with Hyprland. It was the better format on the
  # 1.6-scaled panel — vector, so it stays sharp where XCursor's fixed-size
  # bitmaps get resampled soft — but niri cannot read it: `strings` over the
  # niri binary finds 34 xcursor references and zero for hyprcursor. Leaving it
  # on would have generated a cursor theme nothing loads.
  home.pointerCursor = {
    # `enable` used to be implied by the block existing at all. home-manager
    # deprecated that in 26.11: without this line it now warns and, eventually,
    # stops generating the cursor configuration.
    enable = true;

    package = pkgs.bibata-cursors;
    name = "Bibata-Modern-Ice";
    size = 24;

    gtk.enable = true;
    x11.enable = true;
  };

  gtk = {
    enable = true;

    # Noctalia's gtk template wants to set adw-gtk3-dark over gsettings and
    # skips with "Theme 'adw-gtk3-dark' not found" when the package is absent —
    # which it was, so GTK apps were never actually themed. Declaring the same
    # theme here means settings.ini and gsettings agree instead of racing.
    theme = {
      package = pkgs.adw-gtk3;
      name = "adw-gtk3-dark";
    };

    # home-manager 26.11 changed the default of gtk4.theme from `gtk.theme` to
    # null, and only keeps the old behaviour while home.stateVersion is below
    # "26.05". Stating it explicitly means the GTK4 applications keep the same
    # theme as the GTK3 ones no matter what stateVersion says later — which is
    # what the block above already intended.
    gtk4.theme = {
      package = pkgs.adw-gtk3;
      name = "adw-gtk3-dark";
    };

    # Replaces the dangling `breeze` reference. Papirus also has a Noctalia
    # community template (`papirus-icons`) if you later want the folder colours
    # to follow the palette.
    iconTheme = {
      package = pkgs.papirus-icon-theme;
      name = "Papirus-Dark";
    };

    font = {
      name = "Noto Sans";
      size = 10;
    };

    # Pulls Noctalia's generated palette in from the home-manager-managed
    # gtk.css, which stops apply.sh from rewriting the file. See the header for
    # why this is what keeps the two from fighting on every rebuild.
    #
    # For GTK3 this is the whole file: the theme itself arrives through
    # gtk-theme-name in settings.ini. For GTK4 home-manager prepends the
    # adw-gtk3-dark import and this lands after it, so the palette wins.
    gtk3.extraCss = ''
      @import url("noctalia.css");
    '';
    gtk4.extraCss = ''
      @import url("noctalia.css");
    '';
  };

  # GTK4 reads the colour scheme from the portal rather than settings.ini, and
  # the old settings.ini had prefer-dark-theme=false. Noctalia sets this over
  # gsettings on every theme change too; stating it here means a fresh session
  # starts dark instead of flashing light until the shell comes up.
  dconf.settings."org/gnome/desktop/interface".color-scheme = "prefer-dark";
}
