{
  config,
  lib,
  flake,
  parsedArchToFlake,
  utils,
  pkgs,
  ...
}:
let
  inherit (flake.inputs.nix-snapshotter.packages.${flakeArchBuild}) nix-snapshotter;
  flakeArchBuild = parsedArchToFlake pkgs.stdenv.buildPlatform.parsed;
  mkLayer =
    {
      copyToRoot ? [ ],
      meta ? { },
      defaultDirMode ? "755",
      defaultDirUid ? 0,
      defaultDirGid ? 0,
    }:
    let
      assertionsModule = {
        options = {
          assertions = lib.mkOption {
            type = with lib.types; listOf unspecified;
            default = [ ];
          };
        };
      };
      fsTreeModule = (
        { config, ... }: {
          imports = [ assertionsModule ];

          options = {
            type = lib.mkOption {
              type = lib.types.enum [
                "directory"
                "regular"
                "symlink"
              ];
              default = "directory";
            };

            uid = lib.mkOption {
              type = lib.types.ints.u32;
              default = defaultDirUid;
            };

            gid = lib.mkOption {
              type = lib.types.ints.u32;
              default = defaultDirGid;
            };

            mode = lib.mkOption {
              type = lib.types.str;
              default = defaultDirMode;
            };

            source = lib.mkOption {
              type = with lib.types; nullOr path;
              default = null;
            };

            target = lib.mkOption {
              type = with lib.types; nullOr path;
              default = null;
            };

            contents = lib.mkOption {
              type = with lib.types; nullOr str;
              default = null;
            };

            children = lib.mkOption {
              type = with lib.types; attrsOf (submodule fsTreeModule);
              default = { };
            };
          };

          config = {
            assertions = [
              {
                assertion = config.type == "directory" -> config.source == null;
                message = "Directory can't have 'source' property";
              }
              {
                assertion = config.type == "directory" -> config.target == null;
                message = "Directory can't have 'target' property";
              }
              {
                assertion = config.type == "directory" -> config.contents == null;
                message = "Directory can't have 'contents' property";
              }
              {
                assertion = config.type != "directory" -> config.children == { };
                message = "Only directories can have children";
              }
              {
                assertion = config.type == "symlink" -> config.source == null;
                message = "Symlink can't have 'source' property";
              }
              {
                assertion = config.type == "symlink" -> config.contents == null;
                message = "Symlink can't have 'contents' property";
              }
              {
                assertion = config.type == "symlink" -> config.target != null;
                message = "Symlink must have 'target' property set";
              }
              {
                assertion =
                  config.type == "regular"
                  ->
                    (config.source != null || config.contents != null)
                    && !(config.source != null && config.contents != null);
                message = "Regular file must have set exactly one of properties: 'source' or 'contents'";
              }
              {
                assertion = config.type == "regular" -> config.target == null;
                message = "Regular file can't have 'target' property";
              }
            ];
          };
        }
      );
      # Recursively check assertions from an fs tree (see fsTreeModule).
      fsTreeCheckAssertions =
        let
          f =
            acc: path: node:
            let
              failed = lib.catAttrs "message" (lib.filter (x: !x.assertion) node.assertions);
              acc' =
                if failed != [ ] then
                  acc
                  // {
                    ${path} = failed;
                  }
                else
                  acc;
            in
            if node.children == { } then
              acc'
            else
              lib.foldl' (
                acc:
                { name, value }:
                let
                  path' = "${path}${if path == "/" then "" else "/"}${name}";
                in
                f acc path' value
              ) acc' (lib.attrsToList node.children);
        in
        f { } "/";
      fsTreeConvert =
        let
          f =
            node:
            let
              children = node.children;
            in
            lib.pipe node [
              (
                node:
                lib.removeAttrs node [
                  "children"
                  "assertions"
                ]
              )
              (node: node // { children = lib.mapAttrs (_: f) children; })
              (lib.filterAttrs (_: v: !isNull v))
              (lib.filterAttrs (n: v: n == "children" -> v != { }))
            ];
        in
        f;
      mergeFsTrees =
        treeList:
        let
          t = lib.evalModules {
            modules = lib.singleton fsTreeModule ++ treeList;
          };
          failedAssertions = fsTreeCheckAssertions t.config;
        in
        if failedAssertions != { } then
          throw "\nFailed assertions:\n${
            lib.concatMapStringsSep "\n" (
              { name, value }: "- ${name}\n${lib.concatMapStringsSep "\n" (x: "  - ${x}") value}"
            ) (lib.attrsToList failedAssertions)
          }"
        else
          fsTreeConvert t.config;
      checkAllMetadataApplied =
        tree:
        let
          knownPaths =
            let
              f =
                path: node:
                lib.foldr (
                  { name, value }:
                  acc:
                  let
                    childPath = "${path}/${name}";
                  in
                  acc // (f childPath value)
                ) (g (if path == "" then "/" else path) node) (lib.attrsToList (node.children or { }));
              g = path: node: { ${path} = { }; };
            in
            f "" tree;
          notApplied = lib.pipe meta [
            (lib.filterAttrs (n: v: !(knownPaths ? ${n})))
            lib.attrNames
          ];
        in
        if lib.length notApplied > 0 then
          lib.warn ''
            Could not apply permissions to following files:
            ${lib.concatMapStringsSep "\n" (x: "- ${x}") notApplied}
          '' tree
        else
          tree;

      # Convert sequence of file entries into filesystem tree.
      # e.g.
      # [
      #   {type = "directory"; uid = 0; gid = 0; mode = "755"; path = "/"; };
      #   {type = "directory"; uid = 0; gid = 0; mode = "755"; path = "/run"; };
      #   {type = "directory"; uid = 0; gid = 0; mode = "755"; path = "/run/systemd"; };
      #   {type = "file"; uid = 0; gid = 0; mode = "644"; path = "/run/systemd/systemd-units-load"; contents = ""; };
      #   {type = "directory"; uid = 0; gid = 0; mode = "755"; path = "/usr/bin"; };
      #   ...
      # ]
      # into a tree structure (Nix attrsets):
      # {
      #   "/" = {
      #     type: "directory";
      #     uid = 0;
      #     gid = 0;
      #     mode = "755";
      #     children = {
      #       "run" = {
      #         type = "directory";
      #         uid = 0;
      #         gid = 0;
      #         mode = "755";
      #         children = {
      #           "systemd" = {
      #             type = "directory";
      #             uid = 0;
      #             gid = 0;
      #             mode = "755";
      #             children = {
      #               systemd-units-load = {
      #                 type = "file";
      #                 uid = 0;
      #                 gid = 0;
      #                 mode = "644";
      #                 contents = "";
      #               };
      #             };
      #           };
      #         };
      #       };
      #       "usr" = {
      #         # /usr directory is not present as part of input file list, but /usr/bin is.
      #         # In that case recursively create missing directories, setting theirs uid, gid, and mode properties
      #         # to defaultDirUid, defaultDirGid and defaultDirMode.
      #         type = "directory";
      #         uid = 0;
      #         gid = 0;
      #         mode = "755";
      #       };
      #     };
      #   };
      # }
      buildFsTree =
        list:
        let
          buildTree =
            list:
            let
              mkTreeEntry =
                args@{ path, ... }:
                let
                  path' =
                    # must be absolute
                    assert lib.strings.hasPrefix "/" path;
                    lib.pipe path [
                      (lib.splitString "/")
                      (
                        components:
                        let
                          hasTrailingSlash = lib.last components == "";
                        in
                        {
                          inherit components hasTrailingSlash;
                        }
                      )
                      (
                        p:
                        p
                        // {
                          components = lib.filter (v: v != "") p.components;
                        }
                      )
                    ];
                  setByPath =
                    path: value:
                    let
                      len = lib.length path;
                      atDepth =
                        n:
                        if n == len then
                          value
                        else if n == len - 1 then
                          { ${lib.elemAt path n} = atDepth (n + 1); }
                        else
                          { ${lib.elemAt path n}.children = atDepth (n + 1); };
                    in
                    atDepth 0;
                in
                setByPath path'.components (lib.removeAttrs args [ "path" ]);
            in
            lib.pipe list [
              (lib.foldl' (acc: e: acc ++ [ { children = mkTreeEntry e; } ]) [ ])
              mergeFsTrees
            ];
          applyMetadataOverrides =
            let
              f =
                path: value:
                g path value
                // {
                  children = lib.mapAttrs (n: f "${path}/${n}") (value.children or { });
                };
              g =
                path: value:
                let
                  path' = if path == "" then "/" else path;
                in
                if meta ? ${path'} then
                  (lib.mapAttrs (_: lib.mkForce) { inherit (meta.${path'}) uid gid mode; })
                else
                  { };
            in
            f "";
        in
        lib.pipe list [
          buildTree
          (
            v:
            mergeFsTrees [
              v
              (applyMetadataOverrides v)
            ]
          )
        ];
      # Inverse of buildFsTree, convert tree into ordered list of entries, as expected by mklayer.
      fsTreeToList =
        tree:
        let
          f =
            path: node:
            lib.foldr (
              { name, value }:
              acc:
              let
                childPath = "${path}/${name}";
              in
              acc ++ (f childPath value)
            ) [ (g (if path == "" then "/" else path) node) ] (lib.attrsToList (node.children or { }));
          g = path: node: (removeAttrs node [ "children" ]) // { inherit path; };
        in
        f "" tree;
      getFileList =
        pkg:
        let
          file =
            pkgs.runCommand "${pkg.name}-file-list"
              {
                nativeBuildInputs = with pkgs; [ jq ];
              }
              ''
                cd ${pkg}
                while IFS= read -rd "" type &&
                      IFS= read -rd "" mode &&
                      IFS= read -rd "" target &&
                      IFS= read -rd "" path; do
                  case "$type" in
                    d) type_json=directory ;;
                    f) type_json=regular ;;
                    l) type_json=symlink ;;
                    *)
                      echo "unsupported file type '$type'"
                      exit 1
                    ;;
                  esac
                  jq \
                    --arg type "$type_json" \
                    --argjson uid 0 \
                    --argjson gid 0 \
                    --arg mode "$mode" \
                    --arg target "$target" \
                    --arg path "$path" \
                    -Rnc '
                    {
                      type: $type,
                      uid: $uid,
                      gid: $gid,
                      mode: $mode,
                      path: "/" + ($path | ltrimstr("./")),
                    } + if $type == "symlink" then { target: $target } else {} end
                  ' >> $out
                done < <(find -mindepth 1 -printf '%y\0%m\0%l\0%p\0')
              '';
        in
        lib.pipe file [
          builtins.readFile
          (lib.splitString "\n")
          (lib.filter (x: x != ""))
          (map builtins.unsafeDiscardStringContext)
          (map builtins.fromJSON)
          (map (e: if e.type == "regular" then e // { source = "${pkg}${e.path}"; } else e))
          buildFsTree
        ];
      filesFromCopyToRoot =
        let
          eval = lib.evalModules {
            modules = lib.singleton fsTreeModule ++ map getFileList copyToRoot;
          };

          failedAssertions = fsTreeCheckAssertions eval.config;
        in
        if failedAssertions != { } then
          throw "\nFailed assertions:\n${
            lib.concatMapStringsSep "\n" (
              { name, value }: "- ${name}\n${lib.concatMapStringsSep "\n" (x: "  - ${x}") value}"
            ) (lib.attrsToList failedAssertions)
          }"
        else
          lib.pipe eval.config [
            fsTreeConvert
            checkAllMetadataApplied
          ];
      mklayer = pkgs.callPackage ../../../packages/mklayer.nix { };
    in
    pkgs.runCommand "layer.tar"
      {
        nativeBuildInputs = [ mklayer ];
        passAsFile = [ "spec" ];
        spec = lib.pipe filesFromCopyToRoot [
          fsTreeToList
          (map builtins.toJSON)
          (lib.concatStringsSep "\n")
        ];
      }
      ''
        mklayer - --output $out < $specPath
      '';
  withLayers =
    { base, layers }:
    pkgs.runCommand base.name
      {
        nativeBuildInputs = with pkgs; [
          umoci
          jq
        ];
      }
      ''
        mkdir temp
        cd temp
        tar xf ${base}
        if [ ! -f oci-layout ]; then
          echo "No oci-layout" >&2
          exit 1
        fi

        temp="$(jq -r '.mediaType == "application/vnd.oci.image.index.v1+json" and .schemaVersion == 2' < index.json)"
        if [ "$temp" != "true" ]; then
          echo "Unsupported $(jq -r '.mediaType + " schema v" + (.schemaVersion | tostring)' < index.json) for index" >&2
          exit 1
        fi

        temp="$(jq -r '.manifests | length' < index.json)"
        if [ "$temp" != 1 ]; then
          echo "Expected exactly 1 manifest in the index" >&2
          exit 1
        fi

        tag="$(jq -r '.manifests.[].annotations."org.opencontainers.image.ref.name"' < index.json)"
        if [ "$tag" == "null" ]; then
          echo "Can't determine image tag" >&2
          exit 1
        fi

        ${lib.concatMapStringsSep "\n" (layer: "umoci raw add-layer --image \"$PWD:$tag\" ${layer}") layers}
        tar cf $out *
      '';
in
{
  options = {
    system.build.nix-snapshotter = lib.mkOption {
      type = lib.types.package;
      internal = true;
      readOnly = true;
    };
  };

  config = {
    system.build.nix-snapshotter =
      let
        copyToRoot = [
          config.system.build.toplevel
          config.system.build.etc
        ]
        ++ lib.optional config.security.enableWrappers config.security.wrapperPackage;
      in
      withLayers {
        base =
          let
            name =
              if (config.system.nixos.containerName != null) then
                config.system.nixos.containerName
              else
                "nixos-${config.system.nixos.label}";
            tag = "latest";
            baseName = lib.baseNameOf name;
            imageName = lib.toLower name;
            imageRef = "${imageName}:${tag}";

            nix-snapshotter-config = {
              cmd = [
                (utils.toShellPath config.users.users.root.shell)
                "--login"
              ];
              env = lib.mapAttrsToList (n: v: "${n}=${v}") config.environment.variables;
            };
            configFile = pkgs.writeText "config-${baseName}.json" (builtins.toJSON nix-snapshotter-config);
            runtimeClosureInfo = pkgs.closureInfo {
              rootPaths = [ configFile ] ++ copyToRoot;
            };
          in
          pkgs.runCommand "nix-image-${baseName}.tar"
            {
              nativeBuildInputs = [ nix-snapshotter ];
              passthru = {
                inherit name tag;
                image = imageRef;
              };
            }
            ''
              echo '[]' > empty
              nix2container build \
                --config "${configFile}" \
                --closure "${runtimeClosureInfo}/store-paths" \
                --copy-to-root empty \
                --ref "${imageRef}" \
                $out
            '';
        layers = [
          (mkLayer {
            inherit copyToRoot;
            meta = lib.listToAttrs (
              map (v: {
                name = v.file;
                value = {
                  inherit (v) uid gid mode;
                };
              }) config.system.build.perms
            );
          })
        ];
      };
  };
}
