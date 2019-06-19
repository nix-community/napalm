# The napalm nix support for building npm package.
# See 'buildPackage'.
# This file describes the build logic for buildPackage, as well as the build
# description of the napalm-registry. Some tests are also present at the end of
# the file.

{ pkgs ? import ./nix {}
}:
with rec
{

  # Reads a package-lock.json and assembles a snapshot with all the packages of
  # which the URL and sha are known. The resulting snapshot looks like the
  # following:
  #   { "my-package":
  #       { "1.0.0": { url = "https://npmjs.org/some-tarball", shaX = ...};
  #         "1.2.0": { url = "https://npmjs.org/some-tarball2", shaX = ...};
  #       };
  #     "other-package": { ... };
  #   }
  snapshotFromPackageLockJson = packageLockJson:
    with rec
      { packageLock = builtins.fromJSON (builtins.readFile packageLockJson);

        # XXX: Creates a "node" for genericClosure. We include whether or not
        # the packages contains an integrity, and if so the integriy as well,
        # in the key. The reason is that the same package and version pair can
        # be found several time in a package-lock.json.
        mkNode = name: obj:
          { key =
              if builtins.hasAttr "integrity" obj
              then "${name}-${obj.version}-${obj.integrity}"
              else "${name}-${obj.version}-no-integrity";
            inherit name obj;
            inherit (obj) version;
            next =
              if builtins.hasAttr "dependencies" obj
              then pkgs.lib.mapAttrsToList mkNode (obj.dependencies)
              else [];
          };

        # The list of all packages discovered in the package-lock, excluding
        # the top-level package.
        flattened = builtins.genericClosure
          { startSet = [(mkNode packageLock.name packageLock)] ;
            operator = x: x.next;
          };

        # Create an entry for the snapshot, e.g.
        #     { some-package = { some-version = { url = ...; shaX = ...} ; }; }
        snapshotEntry = x:
          with rec
            { sha =
                if pkgs.lib.hasPrefix "sha1-" x.obj.integrity
                then { sha1 = pkgs.lib.removePrefix "sha1-" x.obj.integrity; } else
                if pkgs.lib.hasPrefix "sha512-" x.obj.integrity
                then { sha512 = pkgs.lib.removePrefix "sha512-" x.obj.integrity; }
                else abort "Unknown sha for ${x.obj.integrity}";
            };
          if builtins.hasAttr "resolved" x.obj
          then
            { "${x.name}" =
                { "${x.version}" = pkgs.fetchurl ({ url = x.obj.resolved; } // sha);
                };
            }
          else {};
      };
    pkgs.lib.foldl
    (acc: x:
      (pkgs.lib.recursiveUpdate acc (snapshotEntry x))
    ) {} flattened;

  # Returns either the package-lock or the npm-shrinkwrap. If none is found
  # returns null.
  findPackageLock = src:
    with rec
      { toplevel = builtins.readDir src;
        hasPackageLock = builtins.hasAttr "package-lock.json" toplevel;
        hasNpmShrinkwrap = builtins.hasAttr "npm-shrinkwrap.json" toplevel;
      };
    if hasPackageLock then "${src}/package-lock.json"
    else if hasNpmShrinkwrap then "${src}/npm-shrinkwrap.json"
    else null;

  # Builds an npm package, placing all the executables the 'bin' directory.
  # All attributes are passed to 'runCommand'.
  #
  # TODO: document environment variables that are set by each phase
  buildPackage =
    src:
    attrs@
    { packageLock ? null
    , npmCommands ? [ "npm install" ]
    , ... }:
    with rec
    { actualPackageLock =
        if ! isNull packageLock then packageLock
        else if ! isNull discoveredPackageLock then discoveredPackageLock
        else abort
          ''
            Could not find a suitable package-lock in ${src}.

            If you specify a 'packageLock' to 'buildPackage', I will use that.
            Otherwise, if there is a file 'package-lock.json' in ${src}, I will use that.
            Otherwise, if there is a file 'npm-shrinkwrap.json' in ${src}, I will use that.
            Otherwise, you will see this error message.
          '';
      discoveredPackageLock = findPackageLock src;
      snapshot = pkgs.writeText "npm-snapshot"
        (builtins.toJSON (snapshotFromPackageLockJson actualPackageLock));
      buildInputs =
        [ pkgs.nodejs-10_x
          haskellPackages.napalm-registry
          pkgs.fswatch
          pkgs.gcc
          pkgs.jq
          pkgs.netcat
        ];
      newBuildInputs =
          if builtins.hasAttr "buildInputs" attrs
            then attrs.buildInputs ++ buildInputs
          else buildInputs;
    };
    pkgs.stdenv.mkDerivation
      { inherit src;
        npmCommands = pkgs.lib.concatStringsSep "\n" npmCommands;
        buildInputs = newBuildInputs;

        # TODO: Use package name in derivation name
        name = "build-npm-package";

        configurePhase = "export HOME=$(mktemp -d)";

        buildPhase =
    ''
      runHook preBuild

      # TODO: why does the unpacker not set the sourceRoot?
      sourceRoot=$PWD

      echo "Starting napalm registry"

      napalm-registry --snapshot ${snapshot} &
      napalm_REGISTRY_PID=$!

      while ! nc -z localhost 8081; do
        echo waiting for registry to be alive on port 8081
        sleep 1
      done

      npm config set registry 'http://localhost:8081'

      export CPATH="${pkgs.nodejs-10_x}/include/node:$CPATH"

      echo "Installing npm package"

      echo "$npmCommands"

      echo "$npmCommands" | \
        while IFS= read -r c
        do
          echo "Runnig npm command: $c"
          $c
          echo "Overzealously patching shebangs"
          if [ -d node_modules ]; then find node_modules -type d -name bin | \
            while read file; do patchShebangs $file; done; fi
        done

      echo "Shutting down napalm registry"
      kill $napalm_REGISTRY_PID

      runHook postBuild
    '';
      installPhase =
          ''
      runHook preInstall

      napalm_INSTALL_DIR=''${napalm_INSTALL_DIR:-$out/_napalm-install}
      mkdir -p $napalm_INSTALL_DIR
      cp -r $sourceRoot/* $napalm_INSTALL_DIR

      echo "Patching package executables"
      cat $napalm_INSTALL_DIR/package.json | jq -r ' select(.bin) | .bin | .[]' | \
        while IFS= read -r bin; do
          # https://github.com/NixOS/nixpkgs/pull/60215
          chmod +w $(dirname "$napalm_INSTALL_DIR/$bin")
          chmod +x $napalm_INSTALL_DIR/$bin
          patchShebangs $napalm_INSTALL_DIR/$bin
        done

      mkdir -p $out/bin

      echo "Creating package executable symlinks in bin"
      cat $napalm_INSTALL_DIR/package.json | jq -r ' select(.bin) | .bin | keys[]' | \
        while IFS= read -r key; do
          target=$(cat $napalm_INSTALL_DIR/package.json | jq -r --arg key "$key" '.bin[$key]')
          echo creating symlink for npm executable $key to $target
          ln -s $napalm_INSTALL_DIR/$target $out/bin/$key
        done

      runHook postInstall
          '';
      };

  napalm-registry-source = pkgs.lib.cleanSource ./napalm-registry;
  haskellPackages = pkgs.haskellPackages.override
    { overrides = _: haskellPackages:
        { napalm-registry =
            haskellPackages.callCabal2nix "napalm-registry" napalm-registry-source {};
        };
    };

  napalm-registry-devshell = haskellPackages.shellFor
    { packages = (ps: [ ps.napalm-registry ]);
      shellHook =
        ''
          repl() {
            ghci -Wall napalm-registry/Main.hs
          }

          echo "To start a REPL session, run:"
          echo "  > repl"
        '';
    };

};
{ inherit buildPackage snapshotFromPackageLockJson napalm-registry-devshell;
  hello-world =
    pkgs.runCommand "hello-world-test" {}
      ''
        ${buildPackage ./test/hello-world {}}/bin/say-hello
        touch $out
      '';
  hello-world-deps =
    pkgs.runCommand "hello-world-deps-test" {}
      ''
        ${buildPackage ./test/hello-world-deps {}}/bin/say-hello
        touch $out
      '';
  napalm-registry = haskellPackages.napalm-registry;
  netlify-cli =
    with
      { sources = import ./nix/sources.nix; };
    pkgs.runCommand "netlify-cli-test" {}
      ''
        export HOME=$(mktemp -d)
        ${buildPackage sources.cli {}}/bin/netlify --help
        touch $out
      '';
  deckdeckgo-starter =
    with rec
      { sources = import ./nix/sources.nix;
        starterKitDrv = buildPackage sources.deckdeckgo-starter
          { npmCommands = [ "npm install" "npm run build" ]; };
        starterKit = starterKitDrv.overrideAttrs (oldAttrs:
          { outputs = [ "out" "dist" ];
            postInstall = "ln -s $napalm_INSTALL_DIR/dist $dist";
          });
      };
    pkgs.runCommand "deckdeckgo-starter" {}
      ''
        if [ ! -f ${starterKit.dist}/index.html ]
        then
          echo "Dist wasn't generated"
          exit 1
        else
          touch $out
        fi
      '';

  bitwarden-cli =
    with rec
      { sources = import ./nix/sources.nix;
        bwDrv = buildPackage sources.bitwarden-cli
          { npmCommands =
              [ "npm install"
                "npm run build"
              ];
          };
        bw = bwDrv.overrideAttrs (oldAttrs:
          { # XXX: niv doesn't support submodules :'(
            # we work around that by skipping "npm run sub:init" and installing
            # the submodule manually
            postUnpack =
              ''
                rmdir $sourceRoot/jslib
                cp -r ${sources.bitwarden-jslib} $sourceRoot/jslib
              '';
          });
      };
    pkgs.runCommand "bitwarden-cli" { buildInputs = [bw] ; }
      ''
        export HOME=$(mktemp -d)
        bw --help
        touch $out
      '';
}
