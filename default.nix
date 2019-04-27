# The napalm nix support for building npm package.
# See 'buildPackage'.
# This file describes the build logic for buildPackage, as well as the build
# description of the napalm-registry. Some tests are also present at the end of
# the file.

{ pkgs ? import ./nix {}
, sources ? pkgs.sources or (abort "Please provide a niv-style sources")
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
  buildPackage = src: attrs@{ packageLock ? null, ... }:
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
      runCommandAttrs =
        let newBuildInputs =
          if builtins.hasAttr "buildInputs" attrs
            then attrs.buildInputs ++ buildInputs
          else buildInputs;
        in attrs // { buildInputs = newBuildInputs; } ;
    };
    pkgs.runCommand "build-npm-package" runCommandAttrs
    ''
      echo "Starting napalm registry"

      napalm-registry --snapshot ${snapshot} &

      while ! nc -z localhost 8081; do
        echo waiting for registry to be alive on port 8081
        sleep 1
      done

      npm config set registry 'http://localhost:8081'

      mkdir -p $out/_napalm-install
      cd $out/_napalm-install

      cp -r ${src}/* .

      export CPATH="${pkgs.nodejs-10_x}/include/node:$CPATH"

      # Extremely sad workaround to make sure the scripts are patched before
      # npm tried to use them
      fswatch -0 -r node_modules | \
        while read -d "" event
        do
          [ -x "$event" ] && patchShebangs $event 2>&1 > /dev/null || true
        done 2>&1 > /dev/null &

      echo "Installing npm package"

      npm install --nodedir=${pkgs.nodejs-10_x}/include/node

      echo "Patching package executables"

      cd $out

      cat _napalm-install/package.json | jq -r '.bin | .[]' | \
        while IFS= read -r bin; do
          # https://github.com/NixOS/nixpkgs/pull/60215
          chmod +w $(dirname "_napalm-install/$bin")
          patchShebangs _napalm-install/$bin
        done

      mkdir -p bin

      cat _napalm-install/package.json | jq -r '.bin | keys[]' | \
        while IFS= read -r key; do
          target=$(cat _napalm-install/package.json | jq -r --arg key "$key" '.bin[$key]')
          echo creating symlink for npm executable $key to $target
          ln -s ../_napalm-install/$target bin/$key
        done
    '';

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
    pkgs.runCommand "netlify-cli-test" {}
      ''
        ${buildPackage sources.cli {}}/bin/netlify --help
        touch $out
      '';
}
