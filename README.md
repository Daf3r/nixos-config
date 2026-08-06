# Nixtalia
A starter nix config to try out Noctalia on Niri, Hyprland, and Mango  

Keybinds for all three:  

SUPER + D = App menu  
SUPER + F1 = Control Center  
SUPER + F2 = Settings Menu  
SUPER + F3 = Clipboard History  
SUPER + F4 = Sessions Menu  

SUPER + B = Zen Browser    
SUPER + RETURN = Kitty    


The mango settings are stock for MaoMao's Mango settings. DMS is also included if you want to try it. I think for now, only DMS is officially supporting Mango.  

How to try this easily:  

Install Nix with the Graphical KDE install



Download this folder  
Unzip and but it in home  
cd ~/nixtalia
Delete my hardware-configuration if it is there
sudo cp /etc/nixos/hardware-configuration.nix ~/nixtalia/hardware-configuration.nix
sudo nixos-rebuild switch --flake .#nixtalia-starter  

This will install everything. Then reboot. When you get to the login screen, you can choose your WM in the bottom left.  

Have fun!!  




Make it yours:  

Open configuration.nix in the file editor of your choice file  
  Look for the comments and it will show you where to change some names  
  
Open home.nix  
  Again, look for the comments for what to do to make changes  
  
Open apps.nix  
  The comment will show you where to add new app names to install them. From command line, type ns and then ctrl+n. This will let you search for any programs so you can find the name to add to apps.nix  
  
Add any wallpapers you would like to the ~/nixtalia/Pictures/Wallpapers folder and you will be able to find them in Noctalia  

Any changes you want to make to the WMs should be done in their respective config folder. Noctalia changes can just be done in Noctalia's settings and they will stay.  

Shortcuts  

ns = Nix Search  
nrs = Shortcut to rebuild  
flakeup = Shortcut to update flake  


