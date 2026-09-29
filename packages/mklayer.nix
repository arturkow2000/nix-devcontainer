{
  lib,
  rustPlatform,
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
  cargoFlags = [
    "--package"
    "mklayer"
  ];
in
rustPlatform.buildRustPackage (finalAttrs: {
  name = "mklayer";

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
        (lib.hasPrefix "crates" name')
      ];
  };

  cargoHash = "sha256-OcfsA5OQv3HKDAXLE0016uFW/jtXjUf39+Kub/8wBbI=";
  cargoBuildFlags = cargoFlags;
  cargoTestFlags = cargoFlags;

  meta = {
    mainProgram = "mklayer";
  };
})
