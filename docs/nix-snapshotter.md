# Setting up nix-snapshotter

[nix-snapshotter](https://github.com/pdtpartners/nix-snapshotter/) is not
required to use Nix devcontainers, but it's strongly recommended as it reduces
disk usage and flash wear-out (otherwise all data will have to be copied from
Nix store to containerd, usually few gigabytes).

## NixOS

Use official [instructions](https://github.com/pdtpartners/nix-snapshotter).

Docker is officially unsupported by nix-snapshotter, you need additional setup:

```nix
{
  virtualisation.docker = {
    daemon.settings = {
      features.containerd-snapshotter = true;
      # See known limitations section below.
      storage-driver = "nix";
    };
  };
}
```

## Non NixOS

Currently (as of 22 September 2026) non-NixOS platforms are officially
unsupported, but you can follow instructions below:

- Build nix-snapshotter from source
   ```shell
   git clone --depth=1 https://github.com/pdtpartners/nix-snapshotter
   cd nix-snapshotter
   go build
   sudo cp nix-snapshotter /usr/local/bin/
   ```

- Install systemd services
  ```shell
  sudo cat >/etc/systemd/system/nix-snapshotter.service <<EOF
  [Unit]
  Description=nix-snapshotter - containerd snapshotter that understands nix store paths natively
  After=network.target
  PartOf=containerd.service

  [Service]
  ExecStart=/usr/local/bin/nix-snapshotter
  Environment=PATH=/root/.nix-profile/bin

  [Install]
  WantedBy=multi-user.target
  EOF
  mkdir /etc/systemd/system/containerd.service.requires
  ln -s /etc/systemd/system/nix-snapshotter.service /etc/systemd/system/containerd.service.requires/
  ```

- Configure containerd (write `/etc/containerd/config.toml`)
  ```toml
  version = 4

  # If you want to use multiple architectures with nix-snapshotter (e.g. 32-bit
  # containers on amd64 or arm64) you need to create this section for each
  # architecture.
  [[plugins."io.containerd.transfer.v1.local".unpack_config]]
  differ = "walking"
  # If you are using another architecture you need to update this accordingly.
  # See https://go.dev/doc/install/source#environment
  platform = "linux/amd64"
  snapshotter = "nix"

  [proxy_plugins.nix]
  type = "snapshot"
  address = "/run/nix-snapshotter/nix-snapshotter.sock"
  ```

- Configure docker (write `/etc/docker/daemon.json`)
  ```json
  {
    "features": {
      "containerd-snapshotter": true
    },
    "storage-driver": "nix"
  }
  ```

## Known limitations

If you want to use Docker with non-standard snapshotters such as [stargz](https://github.com/containerd/stargz-snapshotter)
(or literally anything other than `overlayfs`) you are in trouble. Docker
supports setting only one `storage-driver` (contrary to `nerdctl` it doesn't
support `--snapshotter` option). Currently there isn't any way around this
limitation.

In case of ContainerD, depending on your setup (if `nix` isn't your default
snapshotter) you will need to set `--snapshotter nix` every time you launch
Nix container. If you use `overlayfs` you may switch to `nix`, and your non-Nix
containers will work as usually (nix-snapshotter embeds, and falls back to
overlayfs snapshotter for non-Nix images).
