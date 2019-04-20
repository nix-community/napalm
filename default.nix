let
  pkgs = import ./nix {};
  sources = pkgs.sources;

  # https://docs.npmjs.com/files/package-lock.json#dependencies
  readDependenciesPackageLock = src: packageLock:
    with rec
      { mkPackageKey = name: version: "${name}-${version}";
        mkNode = name: obj:
          { inherit name;
            key = mkPackageKey name obj.version;
            doBuild = builtins.isString obj.resolved;
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

  buildNPMPackage = src: { packageLock ? "${src}/package-lock.json" }:
    let

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

    in
      pkgs.runCommand "build-npm-package"
    { buildInputs = [ pkgs.nodejs-10_x ];
    }
    ''
      mkdir -p $out

      cat ${npm_deps} | while IFS= read -r npm_dep || [[ -n "$npm_dep" ]]; do
        echo "INSTALLING $npm_dep"

        # NOTE: this does a full copy of the source, as opposed to symlinks. The
        # reason is that we patch the shebangs later on. There's most likely a
        # way to keep the symlinks, which are more efficient.
        npm install --offline --prefix $out $(npm pack $npm_dep | tail -1)
      done

      cd $out
      ln -s ./node_modules/.bin bin

      patchShebangs node_modules/**/*
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
}
