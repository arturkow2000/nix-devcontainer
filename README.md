# nix-devcontainer

Build [devcontainers](https://containers.dev/) with Nix.

`nix-devcontainer` lets you define a devcontainer the same way you'd define a
NixOS system or a `nix develop` shell, and get back a standard OCI image that
runs in Docker, containerd or Podman.

## Why

Nix works very well creating devshells - quick and easy to setup, reproducible,
but by default Nix environments are not isolated. Nix has built-in support
support for creating OCI containers, but it doesn't provide support for non-NixOS
binaries (so VSCode server won't work), no shell config, etc. nix-devcontainer
implements missing bits and provides sane defaults to get you started quickly.

## Status

I use this personaly since about a year. Initially I kept it private, but
recently I've done some improvements so I publish it now, hoping somebody finds
it useful. Right now I'm sole user of this, so I've focused on implementing the
things personally I need most.

## Features

- Build VSCode-compatible containers using Nix.
- Simple setup.
- Compatible with [nix-snapshotter](https://github.com/pdtpartners/nix-snapshotter/)
- Compatible with Docker, ContainerD, Podman.
- Supports zsh, bash, fish and nushell.

## Quick Start

- Install [Nix](https://nixos.org/download/)
- **Optional:** configure [nix-snapshotter](docs/nix-snapshotter.md)
- Run `nix run .#container-clang.copyToDockerDaemon` (or `nix run .#container-clang.useNixSnapshotter.copyToDockerDaemon`)

## Demo

https://github.com/user-attachments/assets/5d7c10fa-7e38-4e80-8b10-5a747ee1ebf8

