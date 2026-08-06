{ config, pkgs, ... }:

{

  programs.mangohud = {
    enable = true;
    settings = {
      full = true;
      limit_fps = 144;
    };
  };

  home.packages = with pkgs; [
    kdePackages.dolphin
    kdePackages.kate
    vivaldi
    filezilla
    spotify
    vesktop
    pcmanfm
    pywalfox-native
    spicetify-cli
    #You can add any apps you want to install here
  ];
}
