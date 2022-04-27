{ mkDerivation, aeson, base, base16-bytestring, bytestring
, cryptohash, hashable, hpack, lib, optparse-applicative, servant
, servant-server, tar, text, time, unordered-containers, uri-encode
, warp, zlib
}:
mkDerivation {
  pname = "napalm-registry";
  version = "0.0.0";
  src = ./.;
  isLibrary = false;
  isExecutable = true;
  libraryToolDepends = [ hpack ];
  executableHaskellDepends = [
    aeson base base16-bytestring bytestring cryptohash hashable
    optparse-applicative servant servant-server tar text time
    unordered-containers uri-encode warp zlib
  ];
  prePatch = "hpack";
  license = lib.licenses.mit;
}
