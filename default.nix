# The napalm nix support for building npm package.
# See 'buildPackage'.
# This file describes the build logic for buildPackage. Some tests are also
# present at the end of the file.

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
        # the package contains an integrity, and if so the integriy as well, in
        # the key. The reason is that the same package and version pair can be
        # found several time in a package-lock.json.
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
              # TODO: nix should support SRI
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

  preparePackage = tarball:
    pkgs.runCommand "cache"
      { buildInputs = [ pkgs.nodejs-12_x pkgs.openssl pkgs.nix pkgs.jq] ;}
      ''

        old_sha512=$(cat ${tarball} |\
          openssl dgst -sha512 -binary |\
          openssl base64 -A)

        old_sha1=$(cat ${tarball} |\
          openssl dgst -sha1 -binary |\
          openssl base64 -A)

        TEMP_UNPACK=$(mktemp -d)

        tar -C $TEMP_UNPACK -xzf ${tarball}

        cat $TEMP_UNPACK/*/package.json | \
          jq -r ' select(.bin) | .bin | select(type == "object") | .[]' | \
            while IFS= read -r bin; do
              echo $bin
              # https://github.com/NixOS/nixpkgs/pull/60215
              chmod +w $(dirname "$TEMP_UNPACK/*/$bin")
              chmod +x $TEMP_UNPACK/*/$bin
              patchShebangs $TEMP_UNPACK/*/$bin
            done

        cat $TEMP_UNPACK/*/package.json | \
          jq -r ' select(.bin) | .bin | select(type == "string")' | \
            while IFS= read -r bin; do
              # https://github.com/NixOS/nixpkgs/pull/60215
              chmod +w $(dirname "$TEMP_UNPACK/*/$bin")
              chmod +x $TEMP_UNPACK/*/$bin
              patchShebangs $TEMP_UNPACK/*/$bin
            done

        echo "REPACKING"
        # XXX: huge hack to "pretend" we strip one component
        # really instead of having "package/README.md", ... we have
        # "./README.md" (which is what npm expects, since it just strips the
        # first component
        tar -czf tarball.tar.gz -C $TEMP_UNPACK/* .

        export HOME=$(mktemp -d)

        echo caching patched ${tarball}
        npm cache add tarball.tar.gz

        mkdir -p $out
        cp -r $HOME/.npm/_cacache $out

        new_sha512=$(cat tarball.tar.gz |\
          openssl dgst -sha512 -binary |\
          openssl base64 -A)

        key=$(nix-hash tarball.tar.gz)

        mkdir -p $out/.napalm-support/$key

        echo '
          { "old_sha512": "<old_sha512>",
            "old_sha1": "<old_sha1>",
            "new_sha512": "<new_sha512>"
          } ' > $out/.napalm-support/$key/checksums.json

        sed -i "s:<old_sha512>:$old_sha512:" \
          $out/.napalm-support/$key/checksums.json
        sed -i "s:<old_sha1>:$old_sha1:" \
          $out/.napalm-support/$key/checksums.json
        sed -i "s:<new_sha512>:$new_sha512:" \
          $out/.napalm-support/$key/checksums.json
      '';

  prepareCache = tarballs:
    pkgs.symlinkJoin
      { name = "cacache"; paths = map preparePackage tarballs; };

  snapshotTarballs = snapshot:
    pkgs.lib.concatMap builtins.attrValues (builtins.attrValues snapshot);

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
    , npmCommands ? [ "npm install --offline" ]
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
      snapshot = snapshotFromPackageLockJson actualPackageLock;
      snapshotFile = pkgs.writeText "npm-snapshot"
        (builtins.toJSON (snapshotFromPackageLockJson actualPackageLock));
      buildInputs =
        [ pkgs.nodejs-12_x
          pkgs.gcc
          pkgs.jq
          pkgs.netcat
        ];
      newBuildInputs =
          if builtins.hasAttr "buildInputs" attrs
            then attrs.buildInputs ++ buildInputs
          else buildInputs;

      crates = prepareCache (snapshotTarballs snapshot);
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

      # TODO: why doesn't the unpacker set the sourceRoot?
      sourceRoot=$PWD

      #echo "Starting napalm registry"
      export HOME=$(mktemp -d)
      export TMPDIR=$(mktemp -d)
      mkdir -p $HOME/.npm/

      if [ -d ${crates}/_cacache ]
      then
        echo copying cache
        time cp -Lr --no-preserve mode ${crates}/_cacache $HOME/.npm
      fi

      echo verifying cache
      npm cache verify

      sedscript=$(mktemp)

      echo "creating sed script"
      # Replaces all sha1 integrities with sha512
      cat ${crates}/.napalm-support/*/checksums.json |\
        jq -r '. |
          [ "s:sha1-\(.old_sha1):sha512-\(.new_sha512):",
            "s:sha512-\(.old_sha512):sha512-\(.new_sha512):"
          ] | .[]
          ' >> $sedscript

      echo patching lock files
      if [ -f package-lock.json ]
      then
        echo patching package-lock.json
        time sed -i -f $sedscript package-lock.json
      fi
      if [ -f npm-shrinkwrap.json ]
      then
        echo patching npm-shrinkwrap.json
        time sed -i -f $sedscript npm-shrinkwrap.json
      fi

      export CPATH="${pkgs.nodejs-12_x}/include/node:$CPATH"

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

};
{ inherit buildPackage snapshotFromPackageLockJson ;
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
              [ "npm install --offline"
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
