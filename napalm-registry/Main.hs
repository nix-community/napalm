{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeOperators #-}

module Main (main) where

import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class
import Data.Aeson ((.=))
import Data.Hashable (Hashable)
import Data.List
import Data.Proxy
import Data.String (IsString(..))
import Data.Time (UTCTime(..), Day(ModifiedJulianDay))
import Servant.API
import System.Environment (getArgs)
import qualified Codec.Archive.Tar as Tar
import qualified Codec.Compression.GZip as GZip
import qualified Crypto.Hash.SHA1 as SHA1
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Base16 as Base16
import qualified Data.HashMap.Strict as HMS
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Data.Text.Encoding as T
import qualified Network.URI.Encode as URI
import qualified Network.Wai.Handler.Warp as Warp
import qualified Servant as Servant

main :: IO ()
main = do
    [packages] <- getArgs

    snapshot <- Aeson.decodeFileStrict packages >>= \case
      Just snapshot -> pure snapshot
      Nothing -> error $ "Could not parse packages"
    Warp.run 8081 (Servant.serve api (server snapshot))

api :: Proxy API
api = Proxy

server :: Snapshot -> Servant.Server API
server ss =
  servePackageMetadata ss :<|>
  servePackageVersionMetadata ss :<|>
  serveTarball ss

servePackageMetadata :: Snapshot -> PackageName -> Servant.Handler PackageMetadata
servePackageMetadata (unSnapshot -> ss) pn = do
    liftIO $ T.putStrLn $ "Requesting package info for " <> unPackageName pn
    pvs <- maybe
      (error $ "No such package: " <> T.unpack (unPackageName pn))
      pure
      (HMS.lookup pn ss)

    pvs' <- forM (HMS.toList pvs)  $ \(pv, tarPath) ->
      (pv,) <$> liftIO (mkPackageVersionMetadata pn pv tarPath)

    pure $ mkPackageMetadata pn (HMS.fromList pvs')

servePackageVersionMetadata
  :: Snapshot
  -> PackageName
  -> PackageVersion
  -> Servant.Handler PackageVersionMetadata
servePackageVersionMetadata ss pn pv = do
    liftIO $ T.putStrLn $ "Requesting package version info for " <> unPackageName pn <> "@" <> unPackageVersion pv

    tarPath <- maybe
      (error "No such tarball")
      pure
      (getTarPath ss pn pv)

    liftIO $ mkPackageVersionMetadata pn pv tarPath

getTarPath :: Snapshot -> PackageName -> PackageVersion -> Maybe FilePath
getTarPath (unSnapshot -> ss) pn pv = do
    pvs <- HMS.lookup pn ss
    tarPath <- HMS.lookup pv pvs
    pure $ tarPath

serveTarball :: Snapshot -> PackageName -> TarballName -> Servant.Handler Tarball
serveTarball ss pn tarName = do
    liftIO $ T.putStrLn $ "Requesting tarball for " <> unPackageName pn <> ": " <> unTarballName tarName

    (pn', pv) <- maybe
      (error "Could not read tar name")
      pure
      (fromTarballName tarName)

    when (pn' /= pn) $ error "Package names don't match"

    tarPath <- maybe
      (error "No such tarball")
      pure
      (getTarPath ss pn pv)
    liftIO $ Tarball <$> BS.readFile tarPath

toTarballName :: PackageName -> PackageVersion -> TarballName
toTarballName (PackageName pn) (PackageVersion pv) =
    TarballName (pn <> "-" <> pv <> ".tgz")

fromTarballName :: TarballName -> Maybe (PackageName, PackageVersion)
fromTarballName (TarballName (T.reverse -> tn)) = do
    pvn <- T.stripPrefix (T.reverse ".tgz") tn
    let (pv,pn) = T.breakOn "-" pvn
    pn' <- T.stripPrefix "-" pn
    pure (PackageName (T.reverse pn'), PackageVersion (T.reverse pv))

type API =
  Capture "package_name" PackageName :> Get '[JSON] PackageMetadata :<|>
  Capture "package_name" PackageName :>
    Capture "package_version" PackageVersion :>
    Get '[JSON] PackageVersionMetadata :<|>
  Capture "package_name" PackageName :>
    "-" :>
    Capture "tarbal_name" TarballName :>
    Get '[OctetStream] Tarball

newtype PackageTag = PackageTag { _unPackageTag :: T.Text }
  deriving newtype ( Aeson.ToJSONKey, IsString, Hashable )
newtype PackageVersion = PackageVersion { unPackageVersion :: T.Text }
  deriving newtype ( Eq, Ord, Hashable, FromHttpApiData, Aeson.ToJSONKey, Aeson.FromJSONKey, Aeson.ToJSON )
newtype PackageName = PackageName { unPackageName :: T.Text }
  deriving newtype ( Eq, Hashable, FromHttpApiData, Aeson.FromJSONKey, Aeson.ToJSON )

-- | With .tgz extension
newtype TarballName = TarballName { unTarballName :: T.Text }
  deriving newtype FromHttpApiData

newtype Tarball = Tarball { _unTarball :: BS.ByteString }
  deriving newtype (MimeRender OctetStream)

data PackageMetadata = PackageMetadata
  { packageDistTags :: HMS.HashMap PackageTag PackageVersion
  , packageModified :: UTCTime
  , packageName :: PackageName
  , packageVersions :: HMS.HashMap PackageVersion PackageVersionMetadata
  }

mkPackageMetadata
  :: PackageName
  -> HMS.HashMap PackageVersion PackageVersionMetadata
  -> PackageMetadata
mkPackageMetadata pn pvs = PackageMetadata
    { packageDistTags = HMS.singleton "latest" latestVersion
    , packageModified = UTCTime (ModifiedJulianDay 0) 0
    , packageName = pn
    , packageVersions = pvs
    }
  where
    latestVersion = maximum (HMS.keys pvs)

instance Aeson.ToJSON PackageMetadata where
  toJSON pm = Aeson.object
    [ "versions" .= packageVersions pm
    , "name" .= packageName pm
    , "dist-tags" .= packageDistTags pm
    , "modified" .= packageModified pm
    ]

-- | Basically the package.json
newtype PackageVersionMetadata = PackageVersionMetadata
  { _unPackageVersionMetadata :: Aeson.Value }
  deriving newtype ( Aeson.ToJSON )

sha1sum :: FilePath -> IO T.Text
sha1sum fp = hash <$> BS.readFile fp
  where
    hash = T.decodeUtf8 . Base16.encode . SHA1.hash

mkPackageVersionMetadata :: PackageName -> PackageVersion -> FilePath -> IO PackageVersionMetadata
mkPackageVersionMetadata pn pv tarPath = do
    shasum <- sha1sum tarPath :: IO T.Text

    let
      tarName = toTarballName pn pv
      tarURL = mkTarballURL pn tarName
      dist = Aeson.object
        [ "shasum" .= shasum
        , "tarball" .= tarURL
        ]

    packageJson <- readPackageJson tarPath

    pure $ PackageVersionMetadata $
      Aeson.Object $
      HMS.singleton "dist" dist <> packageJson

mkTarballURL :: PackageName -> TarballName -> T.Text
mkTarballURL
  (URI.encodeText . unPackageName -> pn)
  (URI.encodeText . unTarballName -> tarName)
  = "http://" <> T.intercalate "/" [ "localhost:8081", pn, "-", tarName ]

readPackageJson :: FilePath -> IO Aeson.Object
readPackageJson fp = do
    tar <- GZip.decompress <$> BL.readFile fp

    packageJsonRaw <- maybe
      (error $ "Could not find package JSON for package " <> fp)
      pure
      $ Tar.foldEntries
          (\e -> case Tar.entryContent e of
            Tar.NormalFile bs _size
              | "package.json" `isSuffixOf` Tar.entryPath e -> (Just bs <|>)
            _ -> (Nothing <|>)
          ) Nothing (const Nothing) (Tar.read tar)

    packageJson <- maybe
      (error $ "Could not parse package JSON: " <>
        (T.unpack $ T.decodeUtf8 $ BL.toStrict packageJsonRaw)
      )
      pure
      (Aeson.decode packageJsonRaw) :: IO Aeson.Object

    pure $ packageJson

newtype Snapshot = Snapshot
  { unSnapshot :: HMS.HashMap PackageName (HMS.HashMap PackageVersion FilePath)
  }
  deriving newtype ( Aeson.FromJSON )
