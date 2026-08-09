{ fetchurl }:
let
  version = "1.0.0";
in
{
  src = fetchurl {
    url = "https://example.invalid/thing-${version}.deb";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };
}
