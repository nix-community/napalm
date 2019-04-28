# Napalm

> When faced with a JavaScript codebase, napalm is just what you need.
>
> -- anonymous

* [Building npm packages in Nix](#building-npm-packages-in-nix)
* [Napalm - a lightweight npm registry](#napalm---a-lightweight-npm-registry)

## Building npm packages in Nix

Use the `buildPackage` function provided in the [`default.nix`](./default.nix)
for building npm packages (replace `<napalm>` with the path to napalm;
with [niv]: `niv add nmattia/napalm`):

``` nix
let
    napalm = pkgs.callPackage <napalm> {};
in napalm.buildPackage ./. {}
```

All executables provided by the npm package will be available in the
derivation's `bin` directory.

**NOTE**: napalm uses the package's `package-lock.json` (or
`npm-shrinkwrap.json`) for building a package database. Make sure there is
either a `pacakge-lock.json` or `npm-shrinkwrap.json` in the source.
Alternatively provide the path to the package-lock file:

``` nix
let
    napalm = pkgs.callPackage <napalm> { packageLock = <path/to/package-lock>; };
in napalm.buildPackage ./. {}
```

## Napalm - a lightweight npm registry

Under the hood napalm uses its own package regitry. The registry is available
in [default.nix](./default.nix) as `napalm-registry`.

```
Usage: napalm-registry [-v|--verbose] [--endpoint ARG] [--port ARG] --snapshot ARG

Available options:
  -v,--verbose             Print information about requests
  --endpoint ARG           The endpoint of this server, used in the Tarball URL
  --port ARG               The to serve on, also used in the Tarball URL
  --snapshot ARG           Path to the snapshot file. The snapshot is a JSON
                           file. The top-level keys are the package names. The
                           top-level values are objects mapping from version to
                           the path of the package tarball. Example: { "lodash":
                           { "1.0.0": "/path/to/lodash-1.0.0.tgz" } }
  -h,--help                Show this help text
```

[niv]: https://github.com/nmattia/niv
