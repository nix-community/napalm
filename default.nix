# The napalm nix support for building npm package.
# See 'buildPackage'.
# This file describes the build logic for buildPackage, as well as the build
# description of the napalm-registry. Some tests are also present at the end of
# the file.

{ pkgs ? import ./nix {} }:
let
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
    let
      packageLock = builtins.fromJSON (builtins.readFile packageLockJson);

      # XXX: Creates a "node" for genericClosure. We include whether or not
      # the packages contains an integrity, and if so the integriy as well,
      # in the key. The reason is that the same package and version pair can
      # be found several time in a package-lock.json.
      mkNode = name: obj: {
        inherit name obj;
        inherit (obj) version;
        key =
          if builtins.hasAttr "integrity" obj
          then "${name}-${obj.version}-${obj.integrity}"
          else "${name}-${obj.version}-no-integrity";
        next =
          if builtins.hasAttr "dependencies" obj
          then pkgs.lib.mapAttrsToList mkNode (obj.dependencies)
          else [];
      };

      # The list of all packages discovered in the package-lock, excluding
      # the top-level package.
      flattened = builtins.genericClosure {
        startSet = [ (mkNode packageLock.name packageLock) ];
        operator = x: x.next;
      };

      # Create an entry for the snapshot, e.g.
      #     { some-package = { some-version = { url = ...; shaX = ...} ; }; }
      snapshotEntry = x:
        let
          sha =
            if pkgs.lib.hasPrefix "sha1-" x.obj.integrity
            then { sha1 = pkgs.lib.removePrefix "sha1-" x.obj.integrity; } else
              if pkgs.lib.hasPrefix "sha512-" x.obj.integrity
              then { sha512 = pkgs.lib.removePrefix "sha512-" x.obj.integrity; }
              else abort "Unknown sha for ${x.obj.integrity}";
        in
          if builtins.hasAttr "resolved" x.obj
          then
            {
              "${x.name}" = {
                "${x.version}" = pkgs.fetchurl ({ url = x.obj.resolved; } // sha);
              };
            }
          else {};

      mergeSnapshotEntries = acc: x:
        pkgs.lib.recursiveUpdate acc (snapshotEntry x);
    in
      pkgs.lib.foldl
        mergeSnapshotEntries
        {}
        flattened;

  # Returns either the package-lock or the npm-shrinkwrap. If none is found
  # returns null.
  findPackageLock = src:
    let
      toplevel = builtins.readDir src;
      hasPackageLock = builtins.hasAttr "package-lock.json" toplevel;
      hasNpmShrinkwrap = builtins.hasAttr "npm-shrinkwrap.json" toplevel;
    in
      if hasPackageLock then src + "/package-lock.json"
      else if hasNpmShrinkwrap then src + "/npm-shrinkwrap.json"
      else null;

  # Returns the package.json as nix values. If not found, returns an empty
  # attrset.
  readPackageJSON = src:
    let
      toplevel = builtins.readDir src;
      hasPackageJSON = builtins.hasAttr "package.json" toplevel;
    in
      if hasPackageJSON then pkgs.lib.importJSON (src + "/package.json")
      else
        builtins.trace "WARN: package.json not found in ${toString src}" {};

  # Builds an npm package, placing all the executables the 'bin' directory.
  # All attributes are passed to 'runCommand'.
  #
  # TODO: document environment variables that are set by each phase
  buildPackage =
    src:
    attrs@
    { name ? null
    , packageLock ? null
    , npmCommands ? [ "npm install" ]
    , buildInputs ? []
    , installPhase ? null
    , ...
    }:
      let
        # remove all the attributes that are not part of the normal
        # stdenv.mkDerivation interface
        mkDerivationAttrs = builtins.removeAttrs attrs [
          "packageLock"
          "npmCommands"
        ];

        actualPackageLock =
          if ! isNull packageLock then packageLock
          else if ! isNull discoveredPackageLock then discoveredPackageLock
          else abort ''
            Could not find a suitable package-lock in ${src}.

            If you specify a 'packageLock' to 'buildPackage', I will use that.
            Otherwise, if there is a file 'package-lock.json' in ${src}, I will use that.
            Otherwise, if there is a file 'npm-shrinkwrap.json' in ${src}, I will use that.
            Otherwise, you will see this error message.
          '';

        discoveredPackageLock = findPackageLock src;

        snapshot = pkgs.writeText "npm-snapshot"
          (builtins.toJSON (snapshotFromPackageLockJson actualPackageLock));

        newBuildInputs = buildInputs ++ [
          haskellPackages.napalm-registry
          pkgs.fswatch
          pkgs.jq
          pkgs.netcat-gnu
          pkgs.nodejs
        ];

        reformatPackageName = pname:
          let
            # regex adapted from `validate-npm-package-name`
            # will produce 3 parts e.g.
            # "@someorg/somepackage" -> [ "@someorg/" "someorg" "somepackage" ]
            # "somepackage" -> [ null null "somepackage" ]
            parts = builtins.tail (builtins.match "^(@([^/]+)/)?([^/]+)$" pname);
            # if there is no organisation we need to filter out null values.
            non-null = builtins.filter (x: x != null) parts;
          in
            builtins.concatStringsSep "-" non-null;

        packageJSON = readPackageJSON src;
        pname = packageJSON.name or "build-npm-package";
        version = packageJSON.version or "0.0.0";

        # If name is not specified, read the package.json to load the
        # package name and version from the source package.json
        name = attrs.name or "${reformatPackageName pname}-${version}";
      in
        pkgs.stdenv.mkDerivation (
          mkDerivationAttrs // {
            inherit name src;
            npmCommands = pkgs.lib.concatStringsSep "\n" npmCommands;
            buildInputs = newBuildInputs;

            configurePhase = ''
              runHook preConfigure

              export HOME=$(mktemp -d)

              runHook postConfigure
            '';

            buildPhase = ''
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

              export CPATH="${pkgs.nodejs}/include/node:$CPATH"

              echo "Installing npm package"

              echo "$npmCommands"

              echo "$npmCommands" | \
                while IFS= read -r c
                do
                  echo "Runnig npm command: $c"
                  $c || (echo "$c: failure, aborting" && kill $napalm_REGISTRY_PID && exit 1)
                  echo "Overzealously patching shebangs"
                  if [ -d node_modules ]; then find node_modules -type d -name bin | \
                    while read file; do patchShebangs $file; done; fi
                done

              echo "Shutting down napalm registry"
              kill $napalm_REGISTRY_PID

              runHook postBuild
            '';

            installPhase = attrs.installPhase or ''
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
          }
        );

  napalm-registry-source = pkgs.lib.cleanSource ./napalm-registry;

  haskellPackages = pkgs.haskellPackages.override {
    overrides = _: haskellPackages: {
      napalm-registry =
        haskellPackages.callCabal2nix "napalm-registry" napalm-registry-source {};
    };
  };

  napalm-registry-devshell = haskellPackages.shellFor {
    packages = (ps: [ ps.napalm-registry ]);
    shellHook = ''
      repl() {
        ghci -Wall napalm-registry/Main.hs
      }

      echo "To start a REPL session, run:"
      echo "  > repl"
    '';
  };

  nodejs-headers-installer =
    with pkgs;
    writeScript "nodejs-headers-installer" ''
      echo "* Installing nodejs headers in $HOME/.node-gyp/${nodejs.version} ..."
      mkdir -p $HOME/.node-gyp/${nodejs.version}
      echo 9 > $HOME/.node-gyp/${nodejs.version}/installVersion
      ln -sv ${nodejs}/include $HOME/.node-gyp/${nodejs.version}/include
    '';
in
{
  inherit
    buildPackage
    napalm-registry-devshell
    nodejs-headers-installer
    snapshotFromPackageLockJson
    ;


  napalm-registry = haskellPackages.napalm-registry;

  hello-world = pkgs.runCommand "hello-world-test" {}
    ''
      ${buildPackage ./test/hello-world {}}/bin/say-hello
      touch $out
    '';

  hello-world-deps = pkgs.runCommand "hello-world-deps-test" {}
    ''
      ${buildPackage ./test/hello-world-deps {}}/bin/say-hello
      touch $out
    '';

  netlify-cli =
    let
      sources = import ./nix/sources.nix;
    in
      pkgs.runCommand "netlify-cli-test" {}
        ''
          export HOME=$(mktemp -d)
          ${buildPackage sources.cli {}}/bin/netlify --help
          touch $out
        '';

  deckdeckgo-starter =
    let
      sources = import ./nix/sources.nix;
    in
      buildPackage sources.deckdeckgo-starter {
        name = "deckdeckgo-starter";
        npmCommands = [ "npm install" "npm run build" ];
        installPhase = ''
          mv dist $out
        '';
        doInstallCheck = true;
        installCheckPhase = ''
          if [[ ! -f $out/index.html ]]
          then
            echo "Dist wasn't generated"
            exit 1
          else
            echo "All good!"
          fi
        '';
      };

  bitwarden-cli =
    let
      sources = import ./nix/sources.nix;

      bw = buildPackage sources.bitwarden-cli {
        npmCommands = [
          "npm install --ignore-scripts"
          "npm run build"
        ];

        # XXX: niv doesn't support submodules :'(
        # we work around that by skipping "npm run sub:init" and installing
        # the submodule manually
        postUnpack = ''
          rmdir $sourceRoot/jslib
          cp -r ${sources.bitwarden-jslib} $sourceRoot/jslib
        '';
      };
    in
      pkgs.runCommand "bitwarden-cli" { buildInputs = [ bw ]; }
        ''
          export HOME=$(mktemp -d)
          bw --help
          touch $out
        '';
}
