{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.graphics;
  supportGraphics = cfg.nvidia.enable || cfg.mesa.enable;
  corePkgs = with pkgs; [
    # libdrm default meta.outputsToInstall is bin, but we want libs specifically
    libdrm.out
    libgbm
    libglvnd
    vulkan-loader
    wayland
    libx11
    libxext
    libxcb
  ];
in
{
  options.hardware.graphics = {
    nvidia.enable = lib.mkOption {
      description = ''
        Whether to support NVIDIA GPUs through NVIDIA Container Toolkit.

        This option does not install the driver in container, it installs
        dependencies and configures environment, the driver is always provided
        by the host.
      '';
      type = lib.types.bool;
      default = false;
    };

    mesa.enable = lib.mkOption {
      description = ''
        Install Mesa which provides drivers for most of GPUs (except NVIDIA).
      '';
      type = lib.types.bool;
      default = false;
    };
    mesa.package = lib.mkOption {
      description = ''
        The Mesa package to use.
      '';
      type = lib.types.package;
    };
    vulkan = {
      driverFiles = lib.mkOption {
        description = ''
          Set VK_DRIVER_FILES environment variable.
        '';
        type = with lib.types; listOf path;
      };
      layerPath = lib.mkOption {
        description = ''
          Set VK_LAYER_PATH environment variable.
        '';
        type = with lib.types; listOf path;
      };
      implicitLayerPath = lib.mkOption {
        description = ''
          Set VK_IMPLICIT_LAYER_PATH environment variable.
        '';
        type = with lib.types; listOf path;
      };
      disabledLayers = lib.mkOption {
        description = ''
          Set VK_LOADER_LAYERS_DISABLE environment variable.
        '';
        type = with lib.types; listOf str;
      };
    };
    gbm = {
      backendsPath = lib.mkOption {
        description = ''
          Set GBM_BACKENDS_PATH environment variable.
        '';
        type = with lib.types; listOf path;
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf supportGraphics {
      hardware.graphics = {
        vulkan = {
          # NixOS overrides SYSCONFDIR which points under /nix/store/.../etc instead of /etc.
          # Loading of drivers under /usr/share/vulkan/icd.d still works though.
          driverFiles = [
            "/etc/vulkan/icd.d"
            "/usr/share/vulkan/icd.d"
          ];
          layerPath = [
            "/etc/vulkan/explicit_layer.d"
            "/usr/share/vulkan/explicit_layer.d"
          ];
          implicitLayerPath = [
            "/etc/vulkan/implicit_layer.d"
            "/usr/share/vulkan/implicit_layer.d"
          ];
          # This is broken with vscode's and X11 passthru, if layer is enabled and DISPLAY is set
          # vulkan device enumeration hangs forever. I don't know what vscode does, but if we directly bind mount
          # X11 socket into the container it works.
          disabledLayers = [ "VK_LAYER_MESA_device_select" ];
        };
        gbm = {
          # NixOS defaults look in /run/opengl-driver/lib/gbm, invalid in containers.
          backendsPath = [
            # This is where mesa installs
            "/usr/lib/gbm"
          ]
          # Mesa installs under lib64
          ++ lib.optional pkgs.stdenv.hostPlatform.is64bit "/usr/lib64/gbm";
        };
      };

      programs.nix-ld.libraries = corePkgs;
      environment.systemPackages = corePkgs;
      environment.variables = {
        VK_DRIVER_FILES = lib.concatStringsSep ":" cfg.vulkan.driverFiles;
        VK_LAYER_PATH = lib.concatStringsSep ":" cfg.vulkan.layerPath;
        VK_IMPLICIT_LAYER_PATH = lib.concatStringsSep ":" cfg.vulkan.implicitLayerPath;
        VK_LOADER_LAYERS_DISABLE = lib.concatStringsSep "," cfg.vulkan.disabledLayers;
        GBM_BACKENDS_PATH = lib.concatStringsSep ":" cfg.gbm.backendsPath;
        # Don't set __EGL_VENDOR_LIBRARY_FILENAMES and __EGL_EXTERNAL_PLATFORM_CONFIG_FILENAMES
        # Contrary to vulkan loader glvnd does not support directories here. Fortunately nvidia
        # installs those files under /usr instead of /etc.
      };
    })
    (lib.mkIf cfg.mesa.enable {
      hardware.graphics.mesa.package = lib.mkDefault pkgs.mesa;
      environment.systemPackages = [ cfg.mesa.package ];
    })
    (lib.mkIf cfg.nvidia.enable {
      environment.variables = {
        # We need both paths here.
        # - first path contains system libs. Most apps that will run in the container
        #   are binaries patched by Nix so theirs PT_INTERP points to /nix/store/.../ld-linux instead
        #   of standard /lib/ld-linux thus skipping nix-ld. nvidia drivers depend on some system libs
        #   but they are not patched so linker doesn't know where to look depencies.
        # - on 64-bit platforms nvidia installs drivers in /usr/lib64, nvidia libs may depend on another nvidia libs.
        #
        # This is terrible hack but I couldn't come up with anything better.
        # NixOS disables lookup at /usr/lib and /etc (no ld.so.conf) at compile time.
        LD_LIBRARY_PATH = lib.concatStringsSep ":" (
          lib.singleton "/usr/lib" ++ lib.optional pkgs.stdenv.hostPlatform.is64bit "/usr/lib64"
        );
      };
    })
  ];
}
