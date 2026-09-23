{
  lib,
  rustPlatform,
  protobuf,
}:
let
  stripNixDerivationPath =
    path:
    let
      p0 = lib.removePrefix builtins.storeDir path;
      p1 = lib.removePrefix "/" p0;
      p2 = lib.splitString "/" p1;
    in
    lib.concatStringsSep "/" (lib.drop 1 p2);
in
rustPlatform.buildRustPackage (finalAttrs: {
  name = "nix2docker";

  src = lib.cleanSourceWith {
    src = lib.cleanSource ./..;
    filter =
      name: type:
      let
        name' = stripNixDerivationPath name;
      in
      builtins.any (x: x) [
        (name' == "Cargo.toml")
        (name' == "Cargo.lock")
        (name' == "crates")
        (name' == "crates/nix2docker")
        (lib.hasPrefix "crates/nix2docker/" name')
      ];
  };

  cargoHash = "sha256-ANcAEWtstkLKMqgUURzoALOvxW04h50IJCJwXU7qW+I=";

  nativeBuildInputs = [ protobuf ];
  meta = {
    mainProgram = "nix2docker";
  };
})
