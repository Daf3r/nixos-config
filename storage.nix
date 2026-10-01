{ ... }:

# El segundo NVMe es la instalación de Windows y no se monta desde NixOS.
# Este módulo se conserva como punto explícito para no volver a declarar por
# accidente un montaje Linux sobre esa unidad.
{ }
