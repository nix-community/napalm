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
import qualified Options.Applicative as Opts
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

-- | See 'parseConfig' for field descriptions
data Config = Config
  { configVerbose :: Bool
  , configEndpoint :: T.Text
  , configPort :: Maybe Int
  , configSnapshot :: FilePath
  }

main :: IO ()
main = do
    config <- Opts.execParser (Opts.info (parseConfig <**> Opts.helper) Opts.fullDesc)

    snapshot <- Aeson.decodeFileStrict (configSnapshot config) >>= \case
      Just snapshot -> pure snapshot
      Nothing -> error $ "Could not parse packages"

    let tshow = T.pack . show
    let mkApplication port = Servant.serve api (server baseUrl config snapshot)
          where
            baseUrl = configEndpoint config <> ":" <> tshow port

    (port, app) <- case configPort config of
      Just port -> do
        pure (port, Warp.run port (mkApplication port))
      Nothing -> do
        (port, socket) <- Warp.openFreePort
        pure (port, Warp.runSettingsSocket Warp.defaultSettings socket (mkApplication port))
    T.putStrLn $ "registry is listening on port: " <> tshow port
    app

parseConfig :: Opts.Parser Config
parseConfig = Config <$>
    Opts.switch (
      Opts.long "verbose" <>
      Opts.short 'v' <>
      Opts.help "Print information about requests"
    ) <*>
    Opts.strOption (
      Opts.long "endpoint" <>
      Opts.value "localhost" <>
      Opts.help "The endpoint of this server, used in the Tarball URL"
    ) <*>
    (optional $ Opts.option Opts.auto (
      Opts.long "port" <>
      Opts.help "The to serve on, also used in the Tarball URL"
    )) <*>
    Opts.strOption (
      Opts.long "snapshot" <>
      Opts.help (unwords
        [ "Path to the snapshot file."
        , "The snapshot is a JSON file. The top-level keys are the package"
        , "names. The top-level values are objects mapping from version to the"
        , "path of the package tarball."
        , "Example:"
        , "{ \"lodash\": { \"1.0.0\": \"/path/to/lodash-1.0.0.tgz\" } }"
        ]
      )
    )

api :: Proxy API
api = Proxy

server :: T.Text -> Config -> Snapshot -> Servant.Server API
server baseUrl config ss =
  servePackageMetadata baseUrl config ss :<|>
  servePackageVersionMetadata baseUrl config ss :<|>
  serveTarball config ss

servePackageMetadata :: T.Text -> Config -> Snapshot -> PackageName -> Servant.Handler PackageMetadata
servePackageMetadata baseUrl config (unSnapshot -> ss) pn = do
    when (configVerbose config) $
      liftIO $ T.putStrLn $ "Requesting package info for " <> unPackageName pn
    pvs <- maybe
      (error $ "No such package: " <> T.unpack (unPackageName pn))
      pure
      (HMS.lookup pn ss)

    pvs' <- forM (HMS.toList pvs)  $ \(pv, tarPath) ->
      (pv,) <$> liftIO (mkPackageVersionMetadata baseUrl pn pv tarPath)

    pure $ mkPackageMetadata pn (HMS.fromList pvs')

servePackageVersionMetadata
  :: T.Text
  -> Config
  -> Snapshot
  -> PackageName
  -> PackageVersion
  -> Servant.Handler PackageVersionMetadata
servePackageVersionMetadata baseUrl config ss pn pv = do
    when (configVerbose config) $
      liftIO $ T.putStrLn $ T.unwords
        [ "Requesting package version info for"
        , unPackageName pn <> "@" <> unPackageVersion pv
        ]

    tarPath <- maybe
      (error "No such tarball")
      pure
      (getTarPath ss pn pv)

    liftIO $ mkPackageVersionMetadata baseUrl pn pv tarPath

getTarPath :: Snapshot -> PackageName -> PackageVersion -> Maybe FilePath
getTarPath (unSnapshot -> ss) pn pv = do
    pvs <- HMS.lookup pn ss
    tarPath <- HMS.lookup pv pvs
    pure $ tarPath

serveTarball :: Config -> Snapshot -> PackageName -> TarballName -> Servant.Handler Tarball
serveTarball config ss pn tarName = do
    when (configVerbose config) $
      liftIO $ T.putStrLn $ T.unwords
        [ "Requesting tarball for"
        , unPackageName pn <> ":"
        , unTarballName tarName
        ]

    pv <- maybe (error "Could not parse version") pure $ do
      let pn' = unPackageName pn
      let tn' = unTarballName tarName
      a <- T.stripPrefix (pn' <> "-") tn'
      b <- T.stripSuffix ".tgz" a
      pure $ PackageVersion b

    tarPath <- maybe
      (error "No such tarball")
      pure
      (getTarPath ss pn pv)
    liftIO $ Tarball <$> BS.readFile tarPath

toTarballName :: PackageName -> PackageVersion -> TarballName
toTarballName (PackageName pn) (PackageVersion pv) =
    TarballName (pn <> "-" <> pv <> ".tgz")

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
    -- This is a dummy date
    , packageModified = UTCTime (ModifiedJulianDay 0) 0
    , packageName = pn
    , packageVersions = pvs
    }
  where
    -- XXX: fails if not versions are specified
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

mkPackageVersionMetadata
  :: T.Text
  -> PackageName
  -> PackageVersion
  -> FilePath
  -> IO PackageVersionMetadata
mkPackageVersionMetadata baseUrl pn pv tarPath = do
    shasum <- sha1sum tarPath :: IO T.Text

    let
      tarName = toTarballName pn pv
      tarURL = mkTarballURL baseUrl pn tarName
      dist = Aeson.object
        [ "shasum" .= shasum
        , "tarball" .= tarURL
        ]

    packageJson <- readPackageJson tarPath

    pure $ PackageVersionMetadata $
      Aeson.Object $
      HMS.singleton "dist" dist <> packageJson

mkTarballURL :: T.Text -> PackageName -> TarballName -> T.Text
mkTarballURL
  baseUrl
  (URI.encodeText . unPackageName -> pn)
  (URI.encodeText . unTarballName -> tarName)
  = "http://" <>
    T.intercalate "/"
      [ baseUrl, pn, "-", tarName ]

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
