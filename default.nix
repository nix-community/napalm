{ pkgs ? import ./nix {}
, sources ? pkgs.sources or (abort "Please provide a niv-style sources")
}:
with rec
{
  snapshotFromPackageLockJson = packageLockJson:
    with rec
      { packageLock = builtins.fromJSON (builtins.readFile packageLockJson);
        mkNode = name: obj:
          { key =
              if builtins.hasAttr "integrity" obj
              then
                "${name}-${obj.version}-${obj.integrity}"
              else
                # XXX: tricky AF
                # TODO: explain why
                "${name}-${obj.version}-no-integrity"
                ;
            inherit name obj;
            inherit (obj) version;
            next =
              if builtins.hasAttr "dependencies" obj
              then pkgs.lib.mapAttrsToList mkNode (obj.dependencies)
              else [];
          };
        flattened = builtins.genericClosure
          { startSet = [(mkNode packageLock.name packageLock)] ;
            operator = x: x.next;
          };
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

  findPackageLock = src:
    with rec
      { toplevel = builtins.readDir src;
        hasPackageLock = builtins.hasAttr "package-lock.json" toplevel;
        hasNpmShrinkwrap = builtins.hasAttr "npm-shrinkwrap.json" toplevel;
      };
    if hasPackageLock then "${src}/package-lock.json"
    else if hasNpmShrinkwrap then "${src}/npm-shrinkwrap.json"
    else null;

  buildPackage = src: { packageLock ? null }:
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
    };
    pkgs.runCommand "build-npm-package"
    { buildInputs = [ pkgs.nodejs-10_x pkgs.jq haskellPackages.servant-npm];
    }
    ''
      servant-npm ${snapshot} &

      npm config set registry 'http://localhost:8081'

      mkdir -p $out/_napalm-install
      cd $out/_napalm-install

      cp -r ${src}/* .

      npm install

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

  servant-npm-source = pkgs.lib.cleanSource ./servant-npm;
  haskellPackages = pkgs.haskellPackages.override
    { overrides = _: haskellPackages:
        { servant-npm =
            haskellPackages.callCabal2nix "servant-npm" servant-npm-source {};
        };
    };

  servant-npm-devshell = haskellPackages.shellFor
    { packages = (ps: [ ps.servant-npm ]);
      shellHook =
        ''
          repl() {
            ghci servant-npm/Main.hs
          }

          echo "To start a REPL session, run:"
          echo "  > repl"
        '';
    };

};
{ hello-world =
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
    pkgs.runCommand "netlify-cli-test" {}
      ''
        ${buildPackage sources.cli {}}/bin/netlify --help
        touch $out
      '';

  inherit buildPackage snapshotFromPackageLockJson servant-npm-devshell;
}
