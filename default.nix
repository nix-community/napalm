with rec
{
  pkgs = import ./nix {};
  sources = pkgs.sources;

  #updateDependencies =
    #pkgs.lib.mapAttrs (k: v:
      #let
        #sha =
          #if pkgs.lib.hasPrefix "sha1-" v.integrity
          #then { sha1 = pkgs.lib.removePrefix "sha1-" v.integrity; } else
          #if pkgs.lib.hasPrefix "sha512-" v.integrity
          #then { sha512 = pkgs.lib.removePrefix "sha512-" v.integrity; }
          #else abort "Unknown sha for ${v.integrity}";
      #in
        #(builtins.removeAttrs v ["resolved"]) //
        #(if builtins.hasAttr "resolved" v && builtins.isString v.resolved then
        #{ version = "file://${pkgs.fetchurl ({ url = v.resolved; } // sha)}"; }
        #else {} )//
        #(if builtins.hasAttr "dependencies" v
          #then { dependencies = updateDependencies v.dependencies; }
          #else {}
        #)
        #);

  snapshotFromPackageLockJson = packageLockJson:
    with rec
      { packageLock = builtins.fromJSON (builtins.readFile packageLockJson);
        mkNode = name: obj:
          { key =
              if builtins.hasAttr "integrity" obj
              then
                "${name}-${obj.version}-${obj.integrity}"
              else
                "${name}-${obj.version}-no-integrity" # XXX: tricky AF
                ;
            inherit name obj;
            inherit (obj) version;
            next =
              if builtins.hasAttr "dependencies" obj
              then pkgs.lib.mapAttrsToList mkNode (obj.dependencies)
              else [];
          };
        flattened = builtins.genericClosure
          { startSet = pkgs.lib.mapAttrsToList mkNode packageLock.dependencies;
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

  # https://docs.npmjs.com/files/package-lock.json#dependencies
  readDependenciesPackageLock = src: packageLock:
    with rec
      { mkPackageKey = name: version: "${name}-${version}";
        mkNode = name: obj:
          { inherit name;
            key = mkPackageKey name obj.version;
            doBuild = builtins.hasAttr "resolved" obj && builtins.isString obj.resolved;
            src =
              let
                sha =
                  if pkgs.lib.hasPrefix "sha1-" obj.integrity
                  then { sha1 = pkgs.lib.removePrefix "sha1-" obj.integrity; } else
                  if pkgs.lib.hasPrefix "sha512-" obj.integrity
                  then { sha512 = pkgs.lib.removePrefix "sha512-" obj.integrity; }
                  else abort "Unknown sha for ${obj.integrity}";

              in pkgs.fetchurl
              ({ url = obj.resolved; } // sha) ;
          } // obj;
        mkNodeFromPackageJson = src: packageJson:
          let
            obj = builtins.fromJSON (builtins.readFile packageJson);
            name = obj.name;
            version = obj.version;
          in builtins.removeAttrs ({ inherit src; key = mkPackageKey name obj.version; } // obj) [ "requires" ];
        getDeps = obj:
          if builtins.hasAttr "dependencies" obj
          then pkgs.lib.filter (x: x.doBuild) (pkgs.lib.mapAttrsToList mkNode obj.dependencies)
          else [];
      };
    builtins.genericClosure
      { startSet = [ (mkNodeFromPackageJson src packageLock) ];
        operator = getDeps;
      };

  readDependencies = src: readDependenciesPackageLock src "${src}/package-lock.json";

  updateDependency = snapshot: name: pat:
    let
      topVer = pkgs.lib.head (pkgs.lib.sort (x: y: x > y) (builtins.attrNames snapshot.${name}));
    in "file://${snapshot.${name}.${topVer}}";

  buildNPMPackage = src: { packageLock ? "${src}/package-lock.json" }:
    let

      #newPackageLock =
        #let
          #oldPackageLockJson = builtins.readFile packageLock;
          #oldPackageLockNix = builtins.fromJSON oldPackageLockJson;
          ##newPackageLockNix =
            ##if builtins.hasAttr "dependencies" oldPackageLockNix
            ##then
              ##oldPackageLockNix //
              ##{ dependencies = updateDependencies oldPackageLockNix.dependencies; }
            ##else oldPackageLockNix;
          ##newPackageLockJson = builtins.toJSON newPackageLockNix;
        #in pkgs.writeText "package-lock-json" newPackageLockJson;

      #newPackageJson =
        #let
          #oldPackageJsonJson = builtins.readFile "${src}/package.json";
          #oldPackageJsonNix = builtins.fromJSON oldPackageJsonJson;
          #newPackageJsonNix =
            #if builtins.hasAttr "dependencies" oldPackageJsonNix
            #then
              #oldPackageJsonNix //
              #{ dependencies =
                  #builtins.mapAttrs
                    #(k: v: updateDependency (snapshotFromPackageLockJson packageLock) k v ) oldPackageJsonNix.dependencies; } //
              #{ devDependencies =
                  #builtins.mapAttrs
                    #(k: v: updateDependency (snapshotFromPackageLockJson packageLock) k v ) oldPackageJsonNix.devDependencies; }
            #else oldPackageJsonNix;
          #newPackageJsonJson = builtins.toJSON newPackageJsonNix;
        #in pkgs.writeText "package-json" newPackageJsonJson;
      patchedSource = pkgs.runCommand "patch-package-lock" {}
        ''
          mkdir -p $out
          cp -r ${src}/* $out
          ls $out
          #rm $out/package.json || echo "No package.json"
          #rm $out/package-lock.json || echo "No package-lock.json"
          #rm $out/npm-shrinkwrap.json || echo "No shrinkwrap.json"
        '';

      dependencies =
        let toposorted =
              pkgs.lib.toposort
                (x: y:
                  (builtins.hasAttr "requires" y && builtins.hasAttr x.name y.requires) ||
                  (builtins.hasAttr "dependencies" y &&
                    builtins.hasAttr x.name y.dependencies &&
                    y.dependencies.${x.name}.version == x.version)
                )
                (readDependenciesPackageLock src packageLock);
        in
        if builtins.hasAttr "cycle" toposorted
        then abort "Cycle, sorry: ${builtins.toString (map (x: x.key) toposorted.cycle)}"
        else map (x: x.src) toposorted.result;

      npm_deps = pkgs.writeText "npm_dependencies"
        (pkgs.lib.concatStringsSep "\n" dependencies);

      snapshot = pkgs.writeText "foo" (builtins.toJSON (snapshotFromPackageLockJson packageLock));


    in
      pkgs.runCommand "build-npm-package"
    { buildInputs = [ pkgs.nodejs-10_x pkgs.jq haskellPackages.servant-npm];
    }
    ''
      servant-npm ${snapshot} &

      #mkdir -p $out/_napalm_install
      #mkdir -p "$out/_napalm_npm-global"

      #npm config set prefix "$out/_napalm_npm-global"
      npm config set registry 'http://localhost:8081'

      #export PATH=$out/_napalm_npm-global/bin:$PATH

      #cd $out/_napalm_install

      mkdir -p $out/_napalm-install
      cd $out/_napalm-install

      cp -r ${patchedSource}/* .

      npm install

      cat package.json | jq -r '.bin | .[]' | \
        while IFS= read -r bin; do
          chmod +w $(dirname $bin)
          patchShebangs $bin
        done


      cd ..
      mkdir -p bin
      cat _napalm-install/package.json | jq -r '.bin | keys[]' | \
        while IFS= read -r key; do
          echo $key
          target=$(cat _napalm-install/package.json | jq -r --arg key "$key" '.bin[$key]')
          echo $target
          ln -s ../_napalm-install/$target bin/$key
        done
    '';

  hello-world = buildNPMPackage ./test/hello-world {};
  hello-world-deps = buildNPMPackage ./test/hello-world-deps {};
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
        ${hello-world}/bin/say-hello > $out
      '';
  hello-world-deps =
    pkgs.runCommand "hello-world-deps-test" {}
      ''
        ${hello-world-deps}/bin/say-hello > $out
      '';
  netlify-cli =
    pkgs.runCommand "netlify-cli-test" {}
      ''
        ${buildNPMPackage sources.cli { packageLock = "${sources.cli}/npm-shrinkwrap.json"; }}/bin/netlify --help
        touch $out
      '';

  snapshot = pkgs.writeText "foo" (builtins.toJSON (snapshotFromPackageLockJson "${sources.cli}/npm-shrinkwrap.json"));


  inherit snapshotFromPackageLockJson servant-npm-devshell;
}
