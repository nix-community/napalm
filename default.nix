# The napalm nix support for building npm package.
# See 'buildPackage'.
# This file describes the build logic for buildPackage, as well as the build
# description of the napalm-registry. Some tests are also present at the end of
# the file.

{ pkgs ? import ./nix {} }:
let
  hasFile = dir: filename:
     if pkgs.lib.versionAtLeast builtins.nixVersion "2.3"
     then builtins.pathExists (dir + "/${filename}")
     else builtins.hasAttr filename (builtins.readDir dir);

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
  findPackageLock = root:
    if hasFile root "package-lock.json" then root + "/package-lock.json"
    else if hasFile root "npm-shrinkwrap.json" then root + "/npm-shrinkwrap.json"
    else null;

  # Returns the package.json as nix values. If not found, returns an empty
  # attrset.
  readPackageJSON = root:
    if hasFile root "package.json" then pkgs.lib.importJSON (root + "/package.json")
      else
        builtins.trace "WARN: package.json not found in ${toString root}" {};

  # returns unused ports in a given range
  waitForAndGetPort = pkgs.writeScriptBin "waitForAndGetPort" ''
    #!${pkgs.stdenv.shell}
    PATH="$PATH:${pkgs.coreutils}/bin:${pkgs.gnused}/bin:${pkgs.gnugrep}/bin:${pkgs.lsof}/bin"
    THE_PID=$1
    while ! lsof -Pani -p $THE_PID | grep LISTEN > /dev/null; do
      >&2 echo "Process $THE_PID is not listening to any port yet"
      sleep 1
    done
    lsof -Pani -p $THE_PID | sed -ne 's/.*:\([[:digit:]]*\) (LISTEN)/\1/p'
  '';

  # Builds an npm package, placing all the executables the 'bin' directory.
  # All attributes are passed to 'runCommand'.
  #
  # TODO: document environment variables that are set by each phase
  buildPackage =
    src:
    attrs@
    { name ? null
      # Used by `napalm` to read the `package-lock.json`, `npm-shrinkwrap.json`
      # and `npm-shrinkwrap.json` files. May be different from `src`. When `root`
      # is not set, it defaults to `src`.
    , root ? src
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

        discoveredPackageLock = findPackageLock root;

        snapshot = pkgs.writeText "npm-snapshot"
          (builtins.toJSON (snapshotFromPackageLockJson actualPackageLock));

        newBuildInputs = buildInputs ++ [
          haskellPackages.napalm-registry
          pkgs.fswatch
          pkgs.jq
          pkgs.netcat-gnu
          pkgs.nodejs
          pkgs.lsof
          waitForAndGetPort
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
          in builtins.concatStringsSep "-" non-null;

        packageJSON = readPackageJSON root;
        pname = packageJSON.name or "build-npm-package";
        version = packageJSON.version or "0.0.0";

        # If name is not specified, read the package.json to load the
        # package name and version from the source package.json
        name = attrs.name or "${reformatPackageName pname}-${version}";
      in
        pkgs.stdenv.mkDerivation (mkDerivationAttrs // {
          inherit name src;
          npmCommands = pkgs.lib.concatStringsSep "\n" npmCommands;
          buildInputs = newBuildInputs;

          configurePhase = attrs.configurePhase or "export HOME=$(mktemp -d)";

          buildPhase = attrs.buildPhase or ''
            runHook preBuild

            # TODO: why does the unpacker not set the sourceRoot?
            sourceRoot=$PWD

            echo "Starting napalm registry"
            napalm-registry --snapshot ${snapshot} &
            napalm_REGISTRY_PID=$!
            trap "waitForAndGetPort $napalm_REGISTRY_PID; kill $napalm_REGISTRY_PID" EXIT
            echo "REGISTRY STARTED $napalm_REGISTRY_PID"

            echo "Configure registry for npm"
            REGISTRY_PORT=$(waitForAndGetPort $napalm_REGISTRY_PID)
            echo "Listening on $REGISTRY_PORT"

            npm config set registry "http://localhost:$REGISTRY_PORT"
            npm config get registry

            export CPATH="${pkgs.nodejs}/include/node:$CPATH"

            echo "Installing npm package"

            echo "$npmCommands"

            echo "$npmCommands" | \
              while IFS= read -r c
              do
                echo "Running npm command: $c"
                $c || (echo "$c: failure, aborting" && kill $napalm_REGISTRY_PID && exit 1)
                echo "Overzealously patching shebangs"
                if [ -d node_modules ]; then find node_modules -type d -name bin | \
                  while read file; do patchShebangs $file; done; fi
              done

            runHook postBuild
          '';

          installPhase = attrs.installPhase or ''
            runHook preInstall

            napalm_INSTALL_DIR=''${napalm_INSTALL_DIR:-$out/_napalm-install}
            mkdir -p $napalm_INSTALL_DIR
            cp -r $sourceRoot/* $napalm_INSTALL_DIR

            echo "Patching package executables"
            package_bins=$(jq -cM '.bin' <"$napalm_INSTALL_DIR/package.json")
            echo "bins: $package_bins"
            package_bins_type=$(jq -cMr type <<<"$package_bins")
            echo "bin type: $package_bins_type"

            case "$package_bins_type" in
              object)
                mkdir -p $out/bin

                echo "Creating package executable symlinks in bin"
                while IFS= read -r key; do
                  bin=$(jq -cMr --arg key "$key" '.[$key]' <<<"$package_bins")
                  echo "patching and symlinking binary $key -> $bin"
                  # https://github.com/NixOS/nixpkgs/pull/60215
                  chmod +w $(dirname "$napalm_INSTALL_DIR/$bin")
                  chmod +x $napalm_INSTALL_DIR/$bin
                  patchShebangs $napalm_INSTALL_DIR/$bin
                  ln -s $napalm_INSTALL_DIR/$bin $out/bin/$key
                done < <(jq -cMr 'keys[]' <<<"$package_bins")
                ;;
              string)
                mkdir -p $out/bin
                bin=$(jq -cMr <<<"$package_bins")
                chmod +w $(dirname "$napalm_INSTALL_DIR/$bin")
                chmod +x $napalm_INSTALL_DIR/$bin
                patchShebangs $napalm_INSTALL_DIR/$bin

                ln -s "$napalm_INSTALL_DIR/$bin" "$out/bin/$(basename $bin)"
                ;;
              null)
                echo "No binaries to package"
                ;;
              *)
                echo "unknown type for binaries: $package_bins_type"
                echo "please submit an issue: https://github.com/nmattia/napalm/issues/new"
                exit 1
                ;;
            esac

            runHook postInstall
          '';
        });

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
in
{
  inherit
    waitForAndGetPort
    buildPackage
    napalm-registry-devshell
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
