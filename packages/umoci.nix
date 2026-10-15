{
  lib,
  fetchFromGitHub,
  buildGoModule,
  go-md2man,
  installShellFiles,
}:
buildGoModule (finalAttrs: {
  pname = "umoci";
  version = "0.6.0+21b3491";

  src = fetchFromGitHub {
    owner = "arturkow2000";
    repo = "umoci";
    rev = "21b34916593812f2ad52f670833e34e2939a197f";
    hash = "sha256-O8l1aADEyBUdcZPtk5ToX7+WNLAW9YxOF17rSLFXmfU=";
  };

  vendorHash = null;
  doCheck = false; # Broken in sandbox

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${finalAttrs.version}"
  ];

  nativeBuildInputs = [
    go-md2man
    installShellFiles
  ];

  postInstall = ''
    make docs SHELL="$SHELL"
    installManPage doc/man/*.[1-9]
  '';

  meta = {
    description = "Modifies Open Container images";
    homepage = "https://umo.ci";
    license = lib.licenses.asl20;
    mainProgram = "umoci";
  };
})
