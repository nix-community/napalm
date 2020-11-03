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
import Data.Function
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
  , configPort :: Port
  , configSnapshot :: FilePath
  } deriving Show

data Port = UsePort Int | ReportTo FilePath
  deriving Show

main :: IO ()
main = do
    config <- Opts.execParser (Opts.info (parseConfig <**> Opts.helper) Opts.fullDesc)

    putStrLn "Running napalm registry with config:"
    print config

    snapshot <- Aeson.decodeFileStrict (configSnapshot config) >>= \case
      Just snapshot -> pure snapshot
      Nothing -> error $ "Could not parse packages"
    case configPort config of
      UsePort p ->
        Warp.run p (Servant.serve api (server config p snapshot))
      ReportTo reportTo -> do
        putStrLn "Asking warp for a free port"
        (port,sock) <- Warp.openFreePort
        putStrLn ("Warp picked port " <> show port <> ", reporting to " <> reportTo)
        writeFile reportTo (show port)
        let settings = Warp.defaultSettings & Warp.setPort port
        Warp.runSettingsSocket settings sock (Servant.serve api (server config port snapshot))

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
    (UsePort <$> Opts.option Opts.auto (
      Opts.long "port" <>
      Opts.value 8081 <>
      Opts.help "The to serve on, also used in the Tarball URL"
    ) <|>
    ReportTo <$> Opts.strOption (
      Opts.long "report-to" <>
      Opts.metavar "FILE" <>
      Opts.help "Use a random port and report to FILE"
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

server :: Config -> Warp.Port -> Snapshot -> Servant.Server API
server config port ss =
  serveTarballScoped config ss :<|>
  serveTarballUnscoped config ss :<|> -- this needs to be before servePackageVersionMetadataScoped to avoid conflicts
  servePackageVersionMetadataScoped config port ss :<|>
  servePackageVersionMetadataUnscoped config port ss :<|> -- this needs to be before servePackageMetadataScoped to avoid conflicts
  servePackageMetadataScoped config port ss :<|>
  servePackageMetadataUnscoped config port ss -- this cannot be matched with current servant

servePackageMetadataScoped :: Config -> Warp.Port -> Snapshot -> ScopeName -> PackageName -> Servant.Handler PackageMetadata
servePackageMetadataScoped config port ss sn pn = servePackageMetadata config port ss (ScopedPackageName (Just sn) pn)

servePackageMetadataUnscoped :: Config -> Warp.Port -> Snapshot -> PackageName -> Servant.Handler PackageMetadata
servePackageMetadataUnscoped config port ss pn = servePackageMetadata config port ss (ScopedPackageName Nothing pn)

servePackageMetadata :: Config -> Warp.Port -> Snapshot -> ScopedPackageName -> Servant.Handler PackageMetadata
servePackageMetadata config port (unSnapshot -> ss) pn = do
    let flatPn = flattenScopedPackageName pn
    when (configVerbose config) $
      liftIO $ T.putStrLn $ "Requesting package info for " <> unScopedPackageNameFlat flatPn
    pvs <- maybe
      (error $ "No such package: " <> T.unpack (unScopedPackageNameFlat flatPn))
      pure
      (HMS.lookup flatPn ss)

    pvs' <- forM (HMS.toList pvs)  $ \(pv, tarPath) ->
      (pv,) <$> liftIO (mkPackageVersionMetadata config port pn pv tarPath)

    pure $ mkPackageMetadata pn (HMS.fromList pvs')

servePackageVersionMetadataScoped
  :: Config
  -> Warp.Port
  -> Snapshot
  -> ScopeName
  -> PackageName
  -> PackageVersion
  -> Servant.Handler PackageVersionMetadata
servePackageVersionMetadataScoped config port ss sn pn = servePackageVersionMetadata config port ss (ScopedPackageName (Just sn) pn)

servePackageVersionMetadataUnscoped
  :: Config
  -> Warp.Port
  -> Snapshot
  -> PackageName
  -> PackageVersion
  -> Servant.Handler PackageVersionMetadata
servePackageVersionMetadataUnscoped config port ss pn = servePackageVersionMetadata config port ss (ScopedPackageName Nothing pn)

servePackageVersionMetadata
  :: Config
  -> Warp.Port
  -> Snapshot
  -> ScopedPackageName
  -> PackageVersion
  -> Servant.Handler PackageVersionMetadata
servePackageVersionMetadata config port ss pn pv = do
    when (configVerbose config) $
      liftIO $ T.putStrLn $ T.unwords
        [ "Requesting package version info for"
        , unScopedPackageNameFlat (flattenScopedPackageName pn) <> "#" <> unPackageVersion pv
        ]

    tarPath <- maybe
      (error "No such tarball")
      pure
      (getTarPath ss pn pv)

    liftIO $ mkPackageVersionMetadata config port pn pv tarPath

getTarPath :: Snapshot -> ScopedPackageName -> PackageVersion -> Maybe FilePath
getTarPath (unSnapshot -> ss) pn pv = do
    pvs <- HMS.lookup (flattenScopedPackageName pn) ss
    tarPath <- HMS.lookup pv pvs
    pure $ tarPath

serveTarballScoped :: Config -> Snapshot -> ScopeName -> PackageName -> TarballName -> Servant.Handler Tarball
serveTarballScoped config ss sn pn = serveTarball config ss (ScopedPackageName (Just sn) pn)

serveTarballUnscoped :: Config -> Snapshot -> PackageName -> TarballName -> Servant.Handler Tarball
serveTarballUnscoped config ss pn = serveTarball config ss (ScopedPackageName Nothing pn)

serveTarball :: Config -> Snapshot -> ScopedPackageName -> TarballName -> Servant.Handler Tarball
serveTarball config ss pn tarName = do
    when (configVerbose config) $
      liftIO $ T.putStrLn $ T.unwords
        [ "Requesting tarball for"
        , unScopedPackageNameFlat (flattenScopedPackageName pn) <> ":"
        , unTarballName tarName
        ]

    pv <- maybe (error "Could not parse version") pure $ do
      let pn' = spnName pn -- the tarball filename does not contain scope
      let tn' = unTarballName tarName
      a <- T.stripPrefix (unPackageName pn' <> "-") tn'
      b <- T.stripSuffix ".tgz" a
      pure $ PackageVersion b

    tarPath <- maybe
      (error "No such tarball")
      pure
      (getTarPath ss pn pv)
    liftIO $ Tarball <$> BS.readFile tarPath

toTarballName :: ScopedPackageName -> PackageVersion -> TarballName
toTarballName pn (PackageVersion pv) =
    TarballName (unScopedPackageNameFlat (flattenScopedPackageName pn) <> "-" <> pv <> ".tgz")

flattenScopedPackageName :: ScopedPackageName -> ScopedPackageNameFlat
flattenScopedPackageName (ScopedPackageName Nothing (PackageName pn)) = ScopedPackageNameFlat pn
flattenScopedPackageName (ScopedPackageName (Just (ScopeName sn)) (PackageName pn)) = ScopedPackageNameFlat (sn <> "/" <> pn)

type API =
  Capture "scope_name" ScopeName :>
    Capture "package_name" PackageName :>
    "-" :>
    Capture "tarbal_name" TarballName :>
    Get '[OctetStream] Tarball :<|>
  Capture "package_name" PackageName :>
    "-" :>
    Capture "tarbal_name" TarballName :>
    Get '[OctetStream] Tarball :<|>
  Capture "scope_name" ScopeName :>
    Capture "package_name" PackageName :>
    Capture "package_version" PackageVersion :>
    Get '[JSON] PackageVersionMetadata :<|>
  Capture "package_name" PackageName :>
    Capture "package_version" PackageVersion :>
    Get '[JSON] PackageVersionMetadata :<|>
  Capture "scope_name" ScopeName :> Capture "package_name" PackageName :> Get '[JSON] PackageMetadata :<|>
  Capture "package_name" PackageName :> Get '[JSON] PackageMetadata

newtype PackageTag = PackageTag { _unPackageTag :: T.Text }
  deriving newtype ( Aeson.ToJSONKey, IsString, Hashable )
newtype PackageVersion = PackageVersion { unPackageVersion :: T.Text }
  deriving newtype ( Eq, Ord, Hashable, FromHttpApiData, Aeson.ToJSONKey, Aeson.FromJSONKey, Aeson.ToJSON )
data ScopedPackageName = ScopedPackageName { _spnScope :: Maybe ScopeName, spnName :: PackageName }
  deriving ( Eq )
newtype ScopedPackageNameFlat = ScopedPackageNameFlat { unScopedPackageNameFlat :: T.Text }
  deriving newtype ( Eq, Show, Hashable, Aeson.FromJSONKey, Aeson.ToJSON )
newtype PackageName = PackageName { unPackageName :: T.Text }
  deriving newtype ( Eq, Show, Hashable, FromHttpApiData, Aeson.FromJSONKey, Aeson.ToJSON )
newtype ScopeName = ScopeName { _unScopeName :: T.Text }
  deriving newtype ( Eq, Show, Hashable, FromHttpApiData, Aeson.FromJSONKey, Aeson.ToJSON )

-- | With .tgz extension
newtype TarballName = TarballName { unTarballName :: T.Text }
  deriving newtype FromHttpApiData

newtype Tarball = Tarball { _unTarball :: BS.ByteString }
  deriving newtype (MimeRender OctetStream)

data PackageMetadata = PackageMetadata
  { packageDistTags :: HMS.HashMap PackageTag PackageVersion
  , packageModified :: UTCTime
  , packageName :: ScopedPackageNameFlat
  , packageVersions :: HMS.HashMap PackageVersion PackageVersionMetadata
  }

mkPackageMetadata
  :: ScopedPackageName
  -> HMS.HashMap PackageVersion PackageVersionMetadata
  -> PackageMetadata
mkPackageMetadata pn pvs = PackageMetadata
    { packageDistTags = HMS.singleton "latest" latestVersion
    -- This is a dummy date
    , packageModified = UTCTime (ModifiedJulianDay 0) 0
    , packageName = flattenScopedPackageName pn
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
  :: Config
  -> Warp.Port
  -> ScopedPackageName
  -> PackageVersion
  -> FilePath
  -> IO PackageVersionMetadata
mkPackageVersionMetadata config port pn pv tarPath = do
    shasum <- sha1sum tarPath :: IO T.Text

    let
      tarName = toTarballName pn pv
      tarURL = mkTarballURL config port pn tarName
      dist = Aeson.object
        [ "shasum" .= shasum
        , "tarball" .= tarURL
        ]

    packageJson <- readPackageJson tarPath

    pure $ PackageVersionMetadata $
      Aeson.Object $
      HMS.singleton "dist" dist <> packageJson

mkTarballURL :: Config -> Warp.Port -> ScopedPackageName -> TarballName -> T.Text
mkTarballURL
  config
  port
  (URI.encodeText . unScopedPackageNameFlat . flattenScopedPackageName -> pn)
  (URI.encodeText . unTarballName -> tarName)
  = "http://" <>
    T.intercalate "/"
      [ configEndpoint config <> ":" <> tshow port, pn, "-", tarName ]
  where
    tshow = T.pack . show

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
  { unSnapshot :: HMS.HashMap ScopedPackageNameFlat (HMS.HashMap PackageVersion FilePath)
  }
  deriving newtype ( Aeson.FromJSON )
