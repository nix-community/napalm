let
  pkgs = import ./nix {};
  sources = pkgs.sources;

  updateDependencies =
    pkgs.lib.mapAttrs (k: v:
      let
        sha =
          if pkgs.lib.hasPrefix "sha1-" v.integrity
          then { sha1 = pkgs.lib.removePrefix "sha1-" v.integrity; } else
          if pkgs.lib.hasPrefix "sha512-" v.integrity
          then { sha512 = pkgs.lib.removePrefix "sha512-" v.integrity; }
          else abort "Unknown sha for ${v.integrity}";
      in
        (builtins.removeAttrs v ["resolved"]) //
        (if builtins.hasAttr "resolved" v && builtins.isString v.resolved then
        { version = "file://${pkgs.fetchurl ({ url = v.resolved; } // sha)}"; }
        else {} )//
        (if builtins.hasAttr "dependencies" v
          then { dependencies = updateDependencies v.dependencies; }
          else {}
        )
        );

  snapshotFromPackageLockJson = packageLockJson:
    with rec
      { packageLock = builtins.fromJSON (builtins.readFile packageLockJson);
        mkNode = name: obj:
          { key = "${name}-${obj.version}";
            inherit name obj;
            inherit (obj) version;
            next =
              if builtins.hasAttr "dependencies" obj
              then pkgs.lib.mapAttrsToList mkNode obj.dependencies
              else [];
          };
        flattened = builtins.genericClosure
          { startSet = pkgs.lib.mapAttrsToList mkNode packageLock.dependencies;
            operator = x: x.next;
          };
      };
    pkgs.lib.foldl
    (acc: x:
      with rec
        { sha =
            if pkgs.lib.hasPrefix "sha1-" x.obj.integrity
            then { sha1 = pkgs.lib.removePrefix "sha1-" x.obj.integrity; } else
            if pkgs.lib.hasPrefix "sha512-" x.obj.integrity
            then { sha512 = pkgs.lib.removePrefix "sha512-" x.obj.integrity; }
            else abort "Unknown sha for ${x.obj.integrity}";
          acc' = if builtins.hasAttr "${x.name}" acc then acc else acc // { "${x.name}" = {}; };
          acc'' = acc'.${x.name} //
            { ${x.version} = pkgs.fetchurl ({ url = x.obj.resolved; } // sha);
            };
        };
      acc // { ${x.name} = acc''; }
      ) {} flattened;

  #npmVersionMatch = ver: pat:
    #pkgs.lib.versionOlder pat ver;

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

      newPackageLock =
        let
          oldPackageLockJson = builtins.readFile packageLock;
          oldPackageLockNix = builtins.fromJSON oldPackageLockJson;
          newPackageLockNix =
            if builtins.hasAttr "dependencies" oldPackageLockNix
            then
              oldPackageLockNix //
              { dependencies = updateDependencies oldPackageLockNix.dependencies; }
            else oldPackageLockNix;
          newPackageLockJson = builtins.toJSON newPackageLockNix;
        in pkgs.writeText "package-lock-json" newPackageLockJson;

      newPackageJson =
        let
          oldPackageJsonJson = builtins.readFile "${src}/package.json";
          oldPackageJsonNix = builtins.fromJSON oldPackageJsonJson;
          newPackageJsonNix =
            if builtins.hasAttr "dependencies" oldPackageJsonNix
            then
              oldPackageJsonNix //
              { dependencies =
                  builtins.mapAttrs
                    (k: v: updateDependency (snapshotFromPackageLockJson packageLock) k v ) oldPackageJsonNix.dependencies; } //
              { devDependencies =
                  builtins.mapAttrs
                    (k: v: updateDependency (snapshotFromPackageLockJson packageLock) k v ) oldPackageJsonNix.devDependencies; }
            else oldPackageJsonNix;
          newPackageJsonJson = builtins.toJSON newPackageJsonNix;
        in pkgs.writeText "package-json" newPackageJsonJson;
      patchedSource = pkgs.runCommand "patch-package-lock" {}
        ''
          mkdir -p $out
          cp -r ${src}/* $out
          ls $out
          #rm $out/package.json || echo "No package.json"
          #rm $out/package-lock.json || echo "No package-lock.json"
          #rm $out/npm-shrinkwrap.json || echo "No shrinkwrap.json"
          #cp ${newPackageLock} $out/package-lock.json
          #cp ${newPackageJson} $out/package.json
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
        (pkgs.lib.concatStringsSep "\n" (pkgs.lib.filter (x: ! pkgs.lib.hasPrefix "fsevents" x) dependencies));

    in
      pkgs.runCommand "build-npm-package"
    { buildInputs = [ pkgs.nodejs-10_x pkgs.jq ];
    }
    ''
      mkdir -p $out

      mkdir -p ~/npm-global

      npm config set prefix '~/npm-global'
      npm config set cache-min 9999999

      export PATH=~/npm-global/bin:$PATH

      cat ${npm_deps} | npm install --offline `xargs`
      #cat ${npm_deps} | while IFS= read -r npm_dep || [[ -n "$npm_dep" ]]; do
        #echo INSTALLING $npm_dep
        #npm install --verbose --offline -g $npm_dep
      #done

      #npm install --prefix $out $(npm pack ${patchedSource} | tail -1)

      cat ${patchedSource}/package.json | jq '.'

      cd $out

      ln -s ./node_modules/.bin bin

      echo $out

      #patchShebangs node_modules/**/*
    '';

  hello-world = buildNPMPackage ./test/hello-world {};
  hello-world-deps = buildNPMPackage ./test/hello-world-deps {};
in
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
        ${buildNPMPackage sources.cli { packageLock = "${sources.cli}/npm-shrinkwrap.json"; }}/bin/say-hello > $out
      '';


  inherit snapshotFromPackageLockJson;
}
