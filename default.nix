# The napalm nix support for building npm package.
# See 'buildPackage'.
# This file describes the build logic for buildPackage, as well as the build
# description of the napalm-registry. Some tests are also present at the end of
# the file.

{ pkgs ? import ./nix { }, lib ? pkgs.lib }:
let
  fallbackPackageName = "build-npm-package";
  fallbackPackageVersion = "0.0.0";

  hasFile = dir: filename:
    if lib.versionAtLeast builtins.nixVersion "2.3" then
      builtins.pathExists (dir + "/${filename}")
    else
      builtins.hasAttr filename (builtins.readDir dir);

  # Helper functions
  ifNotNull = a: b: if a != null then a else b;
  ifNotEmpty = a: b: if a != [ ] then a else b;

  concatSnapshots = snapshots:
    let
      allPkgsNames =
        lib.foldl (acc: set: acc ++ (builtins.attrNames set)) [ ]
          snapshots;
      loadPkgVersions = name:
        let
          allVersions =
            lib.foldl (acc: set: acc // set.${name} or { }) { } snapshots;
        in
        {
          inherit name;
          value = allVersions;
        };
    in
    builtins.listToAttrs (builtins.map loadPkgVersions allPkgsNames);

  # Patches shebangs and elfs in npm package and returns derivation
  # which contains package.tgz that is compressed patched package
  #
  # `customAttrs` argument allows user to override any field that is passed
  # into the mkDerivation. It is a function that evaluates to set and overrides
  # current mkDerivation arguments.
  mkNpmTar = { pname, version, src, buildInputs, customAttrs ? null }:
    let
      prev = {
        pname = "${pname}-patched";
        inherit version src buildInputs;

        dontPatch = true;
        dontBuild = true;

        configurePhase = ''
          runHook preConfigure

          # Ensures that fixup phase will use these in the path
          export PATH=${lib.makeBinPath buildInputs}:$PATH

          runHook postConfigure
        '';

        installPhase = ''
          runHook preInstall

          mkdir -p $out/package
          cp -rf ./* $out/package

          runHook postInstall
        '';

        preFixup = ''
          echo Ensuring that proper files are executable ...

          # Split by newline instead of spaces in case
          # some filename contains space
          OLD_IFS=$IFS
          IFS=$'\n'


          # This loop looks for files which may contain shebang
          # and makes them executable if it is the case.
          # This is useful, because patchShbang function patches
          # only files that are executable.
          #
          # See: https://github.com/NixOS/nixpkgs/blob/ba3768aec02b16561ceca1caebdbeb91ae16963d/pkgs/build-support/setup-hooks/patch-shebangs.sh

          for file in $(find $out -type f \( -name "*.js" -or -name "*.sh" \)); do
              grep -i '^#! */' "$file" && \
                  sed -i 's|^#! */|#!/|' "$file" && \
                  chmod +0100 "$file"
          done

          IFS=$OLD_IFS
        '';

        postFixup = ''
          cd $out

          # Package everything up
          echo Packaging ${pname} ...
          tar -czf package.tgz package

          # Remove untared package
          echo Cleanup of ${pname}
          rm -rf ./package
        '';
      };
    in
    pkgs.stdenv.mkDerivation
      (prev // (if customAttrs == null then { } else (customAttrs pkgs prev)));

  # Reads a package-lock.json and assembles a snapshot with all the packages of
  # which the URL and sha are known. The resulting snapshot looks like the
  # following:
  #   { "my-package":
  #       { "1.0.0": { url = "https://npmjs.org/some-tarball", shaX = ...};
  #         "1.2.0": { url = "https://npmjs.org/some-tarball2", shaX = ...};
  #       };
  #     "other-package": { ... };
  #   }
  snapshotFromPackageLockJson =
    { packageLockJson
    , pname ? null
    , version ? null
    , buildInputs ? [ ]
    , patchPackages ? false
    , customPatchPackages ? { }
    }:
    let
      packageLock = builtins.fromJSON (builtins.readFile packageLockJson);

      lockfileVersion = packageLock.lockfileVersion or 1;

      # Load custom name and version of the program in case it was specified and
      # not specified by the package-lock.json
      topPackageName =
        packageLock.name or (ifNotNull pname fallbackPackageName);

      updateTopPackageVersion = obj: {
        version = ifNotNull version fallbackPackageVersion;
      } // obj;

      # Version can be a pointer like “npm:vue-loader@15.10.0”.
      # In that case we need to replace the name and version with the target one.
      parsePointer = { name, version }: let
        isPointer = lib.hasPrefix "npm:" version;
        fragments = lib.splitString "@" (lib.removePrefix "npm:" version);
        name' = if isPointer then builtins.concatStringsSep "@" (lib.init fragments) else name;
        version' = if isPointer then lib.last fragments else version;
      in
      { name = name'; version = version'; };

      parsePackageNameVersion = name': originalObj: parsePointer {
        name = if builtins.hasAttr "name" originalObj then originalObj.name else name';
        version = originalObj.version;
      };

      # XXX: Creates a "node" for genericClosure. We include whether or not
      # the packages contains an integrity, and if so the integrity as well,
      # in the key. The reason is that the same package and version pair can
      # be found several time in a package-lock.json.
      mkNode =
        originalName:
        originalObj:
        let
          inherit (parsePackageNameVersion originalName originalObj) name version;
          obj = originalObj // {
            inherit name version;
          };
        in
        {
          inherit name obj version;
          key = "${name}-${obj.version}-${obj.integrity or "no-integrity"}";
          next = lib.mapAttrsToList mkNode (obj.dependencies or { });
        };

      # The list of all packages discovered in the package-lock, excluding
      # the top-level package.
      flattened = if lockfileVersion < 3
        then builtins.genericClosure {
          startSet = [ (mkNode topPackageName (updateTopPackageVersion packageLock)) ];
          operator = x: x.next;
        }
        else let
          # Parse a path like "node_modules/underscore" into a package name, like "underscore".
          # Also has to support scoped package paths, like "node_modules/@babel/helper-string-parser" and
          # nested packages, like "node_modules/@babel/helper-string-parser/node_modules/underscore".
          pathToName = name: lib.pipe name [
            (builtins.split "(@[^/]+/)?([^/]+)$")
            (builtins.filter (x: builtins.isList x))
            lib.flatten
            (builtins.filter (x: x != null))
            lib.concatStrings
          ];
        in lib.pipe (packageLock.packages or {}) [
          # filter out the top-level package, which has an empty name
          (lib.filterAttrs (name: _: name != ""))
          # Filter out linked packages – they lack other attributes and the link target will be present separately.
          (lib.filterAttrs (_name: originalObj: !(originalObj.link or false)))
          (lib.mapAttrsToList (originalName: originalObj: let
            inherit (parsePackageNameVersion (pathToName originalName) originalObj) name version;
            obj = originalObj // {
              inherit name version;
            };
          in {
            inherit name obj version;
            key = "${name}-${obj.version}-${obj.integrity or "no-integrity"}";
          }))
        ];

      # Create an entry for the snapshot, e.g.
      #     { some-package = { some-version = { url = ...; shaX = ...} ; }; }
      snapshotEntry = x:
        let
          sha =
            if lib.hasPrefix "sha1-" x.obj.integrity then {
              sha1 = lib.removePrefix "sha1-" x.obj.integrity;
            } else if lib.hasPrefix "sha512-" x.obj.integrity then {
              sha512 = lib.removePrefix "sha512-" x.obj.integrity;
            } else
              abort "Unknown sha for ${x.obj.integrity}";
        in
        if builtins.hasAttr "resolved" x.obj then {
          ${x.name}.${x.version} =
            let
              customAttrs =
                let
                  customAttrsOverrider =
                    customPatchPackages.${x.name}.${x.version}
                    or (customPatchPackages.${x.name} or null);
                in
                if builtins.isFunction customAttrsOverrider
                then customAttrsOverrider
                else null;
              src = pkgs.fetchurl ({ url = x.obj.resolved; } // sha);
              out = mkNpmTar {
                inherit src buildInputs;
                pname = lib.strings.sanitizeDerivationName x.name;
                version = x.version;
                inherit customAttrs;
              };
            in
            if patchPackages || customAttrs != null then "${out}/package.tgz" else src;
        } else { };

      mergeSnapshotEntries = acc: x:
        lib.recursiveUpdate acc (snapshotEntry x);
    in
    lib.foldl mergeSnapshotEntries { } flattened;

  # Returns either the package-lock or the npm-shrinkwrap. If none is found
  # returns null.
  findPackageLock = root:
    if hasFile root "package-lock.json" then
      root + "/package-lock.json"
    else if hasFile root "npm-shrinkwrap.json" then
      root + "/npm-shrinkwrap.json"
    else
      null;

  # Returns the package.json as nix values. If not found, returns an empty
  # attrset.
  readPackageJSON = root:
    if hasFile root "package.json" then
      lib.importJSON (root + "/package.json")
    else
      builtins.trace "WARN: package.json not found in ${toString root}" { };

  # Builds an npm package, placing all the executables the 'bin' directory.
  # All attributes are passed to 'runCommand'.
  #
  # TODO: document environment variables that are set by each phase
  buildPackage = src:
    attrs@{ name ? null
    , pname ? null
    , version ? null
      # Used by `napalm` to read the `package-lock.json`, `npm-shrinkwrap.json`
      # and `npm-shrinkwrap.json` files. May be different from `src`. When `root`
      # is not set, it defaults to `src`.
    , root ? src
    , nodejs ? pkgs.nodejs # Node js and npm version to be used, like pkgs.nodejs-16_x
    , packageLock ? null
    , additionalPackageLocks ? [ ] # Sometimes node.js may have multiple package locks.
      # automatic package-lock.json discovery in the root of the project
      # will be used even if this array is specified
    , npmCommands ? "npm install --loglevel verbose --nodedir=${nodejs}/include/node" # These are the commands that are supposed to use npm to install the package.
      # --nodedir argument helps with building node-gyp based packages.
    , buildInputs ? [ ]
    , installPhase ? null
    # Patches shebangs and ELFs in all npm dependencies, may result in slowing down building process
    # if you are having `missing interpreter: /usr/bin/env` issue you should enable this option
    , patchPackages ? false
      # This argument is a set that has structure like: { "<Package Name>" = <override>; ... } or
      # { "<Package name>"."<Package version>" = <override>; ... }, where <override> is a function that takes two arguments:
      # `pkgs` (nixpkgs) and `prev` (default derivation arguments of the package) and returns new arguments that will override
      # current mkDerivation arguments. This works similarly to the overrideAttrs method. See README.md
    , customPatchPackages ? { }
    , preNpmHook ? "" # Bash script to be called before npm call
    , postNpmHook ? "" # Bash script to be called after npm call
    , ...
    }:
      assert name != null -> (pname == null && version == null);
      let
        # Remove all the attributes that are not part of the normal
        # stdenv.mkDerivation interface
        mkDerivationAttrs = builtins.removeAttrs attrs [
          "packageLock"
          "npmCommands"
          "nodejs"
          "packageLock"
          "additionalPackageLocks"
          "patchPackages"
          "customPatchPackages"
          "preNpmHook"
          "postNpmHook"
        ];

        # New `npmCommands` should be just multiline string, but
        # for backwards compatibility there is a list option
        parsedNpmCommands =
          let
            type = builtins.typeOf attrs.npmCommands;
          in
          if attrs ? npmCommands then
            (
              if type == "list" then
                builtins.concatStringsSep "\n" attrs.npmCommands
              else
                attrs.npmCommands
            ) else
            npmCommands;

        actualPackageLocks =
          let
            actualPackageLocks' = additionalPackageLocks ++ [ (ifNotNull packageLock discoveredPackageLock) ];
          in
          ifNotEmpty actualPackageLocks' (abort ''
            Could not find a suitable package-lock in ${src}.
            If you specify a 'packageLock' or 'packageLocks' to 'buildPackage', I will use that.
            Otherwise, if there is a file 'package-lock.json' in ${src}, I will use that.
            Otherwise, if there is a file 'npm-shrinkwrap.json' in ${src}, I will use that.
            Otherwise, you will see this error message.
          '');

        discoveredPackageLock = findPackageLock root;

        snapshot = pkgs.writeText "npm-snapshot" (
          builtins.toJSON (
            concatSnapshots
              (
                builtins.map
                  (lock: snapshotFromPackageLockJson {
                    inherit patchPackages pname version customPatchPackages;
                    packageLockJson = lock;
                    buildInputs = newBuildInputs;
                  })
                  actualPackageLocks
              )
          )
        );

        newBuildInputs = buildInputs ++ [
          haskellPackages.napalm-registry
          pkgs.fswatch
          pkgs.jq
          pkgs.netcat-gnu
          nodejs
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

        packageJSON = readPackageJSON root;
        resolvedPname = attrs.pname or (packageJSON.name or fallbackPackageName);
        resolvedVersion = attrs.version or (packageJSON.version or fallbackPackageVersion);

        # If name is not specified, read the package.json to load the
        # package name and version from the source package.json
        name = attrs.name or "${reformatPackageName resolvedPname}-${resolvedVersion}";

        # Script that will be executed instead of npm.
        # This approach allows adding custom behavior between
        # every npm call, even if it is nested.
        npmOverrideScript = pkgs.writeShellScriptBin "npm" ''
          echo "npm overridden successfully."

          echo "Loading stdenv setup ..."
          source "${pkgs.stdenv}/setup"

          set -e

          echo "Running preNpmHook"
          ${preNpmHook}

          echo "Running npm $@"

          ${nodejs}/bin/npm "$@"

          echo "Running postNpmHook"
          ${postNpmHook}

          echo "Overzealously patching shebangs"
          if [[ -d node_modules ]]; then find node_modules -type d -name bin | \
              while read file; do patchShebangs "$file"; done; fi
        '';
      in
      pkgs.stdenv.mkDerivation (
        mkDerivationAttrs // {
          inherit name src;
          buildInputs = newBuildInputs;

          configurePhase = attrs.configurePhase or ''
            runHook preConfigure

            export HOME=$(mktemp -d)

            runHook postConfigure
          '';

          buildPhase = attrs.buildPhase or ''
            runHook preBuild

            # TODO: why does the unpacker not set the sourceRoot?
            sourceRoot=$PWD

            ${lib.optionalString (patchPackages || customPatchPackages != { }) ''
              echo "Patching npm packages integrity"
              ${if
                # If version of the node.js is below 14.13.0 there is no ESM
                # module support by node.js
                lib.versionAtLeast nodejs.version "14.13.0"
                then nodejs else pkgs.nodejs
               }/bin/node ${./scripts}/lock-patcher.mjs ${snapshot}
            ''}

            echo "Starting napalm registry"

            napalm_REPORT_PORT_TO=$(mktemp -d)/port

            napalm-registry --snapshot ${snapshot} --report-to "$napalm_REPORT_PORT_TO" &
            napalm_REGISTRY_PID=$!

            while [ ! -f "$napalm_REPORT_PORT_TO" ]; do
              echo waiting for registry to report port to "$napalm_REPORT_PORT_TO"
              sleep 1
            done

            napalm_PORT="$(cat "$napalm_REPORT_PORT_TO")"
            rm "$napalm_REPORT_PORT_TO"
            rmdir "$(dirname "$napalm_REPORT_PORT_TO")"

            echo "Configuring npm to use port $napalm_PORT"

            ${nodejs}/bin/npm config set registry "http://localhost:$napalm_PORT"

            export CPATH="${nodejs}/include/node:$CPATH"

            # Makes custom npm script appear before real npm program
            export PATH="${npmOverrideScript}/bin:$PATH"

            echo "Installing npm package"

            ${parsedNpmCommands}

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
        }
      );

  napalm-registry-source = lib.cleanSource ./napalm-registry;

  haskellPackages = pkgs.haskellPackages.override {
    overrides = _: haskellPackages: {
      napalm-registry = haskellPackages.callPackage napalm-registry-source { };
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
  inherit buildPackage napalm-registry-devshell snapshotFromPackageLockJson;

  napalm-registry = haskellPackages.napalm-registry;

  hello-world = pkgs.runCommand "hello-world-test" { } ''
    ${buildPackage ./test/hello-world {}}/bin/say-hello
    touch $out
  '';

  hello-world-deps = pkgs.runCommand "hello-world-deps-test" { } ''
    ${buildPackage ./test/hello-world-deps {}}/bin/say-hello
    touch $out
  '';

  hello-world-deps-v3 = pkgs.runCommand "hello-world-deps-v3-test" { } ''
    ${buildPackage ./test/hello-world-deps-v3 {}}/bin/say-hello
    touch $out
  '';

  hello-world-workspace-v3 = pkgs.runCommand "hello-world-workspace-v3-test" { } ''
    ${buildPackage ./test/hello-world-workspace-v3 {}}/_napalm-install/node_modules/.bin/say-hello
    touch $out
  '';

  # See https://github.com/nix-community/napalm/pull/58#issuecomment-1701202914
  deps-alias = pkgs.runCommand "deps-alias" { } ''
    ${buildPackage ./test/deps-alias {}}/bin/say-hello
    touch $out
  '';

  netlify-cli =
    let
      sources = import ./nix/sources.nix;
    in
    pkgs.runCommand "netlify-cli-test" { } ''
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
        npmCommands = [ "npm install --ignore-scripts" "npm run build" ];

        # XXX: niv doesn't support submodules :'(
        # we work around that by skipping "npm run sub:init" and installing
        # the submodule manually
        postUnpack = ''
          rmdir $sourceRoot/jslib
          cp -r ${sources.bitwarden-jslib} $sourceRoot/jslib
        '';
      };
    in
    pkgs.runCommand "bitwarden-cli" { buildInputs = [ bw ]; } ''
      export HOME=$(mktemp -d)
      bw --help
      touch $out
    '';
}
