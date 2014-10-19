{-# LANGUAGE DeriveGeneric, OverloadedStrings, NamedFieldPuns #-}
module Web.Moonshine (
  Moonshine,
  LoggingConfig(..),
  runMoonshine,
  route,
  makeTimer,
  timerAdd,
  Timer,
  MetricsServer
) where

import Control.Applicative (liftA2)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value(..), (.:?))
import Data.ByteString (ByteString)
import Data.Maybe (fromMaybe)
import Data.Monoid (mempty, mconcat)
import Data.Text.Encoding (decodeUtf8)
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import Data.Yaml (FromJSON(parseJSON), decodeFileEither)
import GHC.Generics (Generic)
import Snap (Snap, quickHttpServe, httpServe, setPort, Config, setSSLCert, setSSLKey, setSSLPort)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Log (Priority(..))
import System.Metrics.Distribution (Distribution)
import System.Remote.Monitoring (Server, forkServerWith)
import qualified Data.Text as T
import qualified System.Metrics as EkgMetrics
import qualified Snap (route)
import qualified System.Metrics.Distribution as D (add)

-- Public Types ---------------------------------------------------------------
-- Semi-Public Types ----------------------------------------------------------

{- |
  This type is the type of things that can be run by the moonshine framework.
  Generate values of this type using `route`, and run the value as a web
  service using `runMoonshine`.
-}
data Moonshine = M [(ByteString, Snap ())]


{- |
  The Timer type.
-}
newtype Timer = T Distribution


{- |
  The metrics server
-}
newtype MetricsServer = Metrics EkgMetrics.Store


{- |
  Logging configuration that Moonshine should use to initialize logging.

  This type is an instance of FromJSON, so you can easily use it in your
  configuration as:

  @
  data MyConfig = MyConfig {
    logging :: LoggingConfig
  } deriving (Generic)
  instance FromJSON MyConfig
  @
-}
data LoggingConfig =
  LoggingConfig {
    level :: LogPriority
  } deriving (Generic)

instance FromJSON LoggingConfig


data ServerConfig =
  ServerConfig {
    applicationConnector :: [ConnectorConfig]
    -- | Configuration for EKG.  Note that although this is a list, at present EKG makes it impossible to support more
    -- than one server. See https://github.com/tibbe/ekg/issues/32.
  , adminConnector :: [ConnectorConfig]
  } deriving (Generic)

instance FromJSON ServerConfig


data ConnectorConfig = ConnectorConfig {
    scheme :: Scheme
  , port :: Int
  , cert :: Maybe FilePath
  , key :: Maybe FilePath
  } deriving (Generic)

instance FromJSON ConnectorConfig


data Scheme = HTTP | HTTPS
  deriving (Generic)

instance FromJSON Scheme


{- |
  A wrapper for Priority, so we can avoid orphan instances
-}
newtype LogPriority = LP Priority

instance FromJSON LogPriority where
  parseJSON (String s) = case reads (T.unpack s) of
    [(priority, "")] -> return (LP priority)
    _ -> fail $ "couldn't parse Priority from string " ++ show s
  parseJSON value = fail $ "Couldn't parse Priority from value " ++ show value


-- Public Functions -----------------------------------------------------------

{- |
  Run a `Moonshine` value that was generated from a user-defined configuration.
  This function never returns.
-}
runMoonshine
  :: (FromJSON userconfig)
  => (userconfig -> MetricsServer -> IO Moonshine)
  -> IO ()
runMoonshine initialize = do
  printBanner
  (userConfig, systemConfig) <- loadConfig configPath
  setupLogging systemConfig
  metricsStore <- EkgMetrics.newStore
  initialize userConfig (Metrics metricsStore) >>= startServer (serverConfig systemConfig) metricsStore
  where
    serverConfig SystemConfig { server = mServerConfig } = fromMaybe defaultServerConfig mServerConfig


{- |
  Like `Snap.route`, but that automatically sets up metrics for the
  specified routes.
-}
route :: [(ByteString, Snap ())] -> Moonshine
route = M


{- |
  Make a new timer with the given name.
-}
makeTimer :: T.Text -> MetricsServer -> IO Timer
makeTimer name (Metrics store) = do
  dist <- getDistribution name store
  return (T dist)


{- |
  Add a time to a timer.
-}
timerAdd :: Timer -> Double -> IO ()
timerAdd (T timer) = D.add timer

-- Private Types --------------------------------------------------------------

{- |
  Defines all the "system" config, where "system" means everything that
  Moonshine knows about.
-}
data SystemConfig =
  SystemConfig {
    logging :: Maybe LoggingConfig
  , server :: Maybe ServerConfig
  }

instance FromJSON SystemConfig where
  parseJSON (Object topLevel) = do
    logging <- topLevel .:? "logging"
    server <- topLevel .:? "server"
    return SystemConfig {logging, server}
  parseJSON value =
    fail $ "Couldn't parse system config from value " ++ show value


-- Private Functions ----------------------------------------------------------

setupLogging :: SystemConfig -> IO ()
setupLogging SystemConfig {logging} = installLoggingConfig (fromMaybe defaultLoggingConfig logging)

defaultLoggingConfig :: LoggingConfig
defaultLoggingConfig = LoggingConfig {
  level = LP INFO
  }

defaultServerConfig = ServerConfig {
    adminConnector = [ConnectorConfig {scheme=HTTP, port=8001, cert=Nothing, key=Nothing}]
  , applicationConnector = [ConnectorConfig {scheme=HTTP, port=8000, cert=Nothing, key=Nothing}]
  }

{- |
  Do all of the things that it takes to get logging set up the way we
  want it.
-}
installLoggingConfig :: LoggingConfig -> IO ()
installLoggingConfig _loggingConfig = do
  -- FIXME
  createDirectoryIfMissing True "log"
  putStrLn "FIXME: setting up logging somehow"


{- |
  hard coded config file path.
-}
configPath :: FilePath
configPath = "config.yml"


{- |
  Load the configuration from YAML.
-}
loadConfig :: FromJSON a => FilePath -> IO (a, SystemConfig)
loadConfig path = do
  eUserConfig <- decodeFileEither path
  eSystemConfig <- decodeFileEither path
  case liftA2 (,) eUserConfig eSystemConfig of
    Left errorMsg -> error $
      "Couldn't decode YAML config from file "
      ++ path ++ ": " ++ show errorMsg
    Right configs -> return configs


{- |
  Find and output a banner.
-}
printBanner :: IO ()
printBanner = do
  exists <- doesFileExist filepath
  banner <- if exists
            then readFile filepath
            else return $ "FIXME: missing " ++ filepath ++ ".  son, I am disappoint\n"
  putStr banner
  where
    filepath = "lib/banner.txt"


{- |
  A replacement for 'System.Remote.Monitoring.getDistribution' that uses an 'EkgMetrics.Store' instead of a 'Server'.
-}
getDistribution :: T.Text -> EkgMetrics.Store -> IO Distribution
getDistribution name store = EkgMetrics.createDistribution name store

{- |
  Start application listening on the ports given by the config.
-}
startServer :: ServerConfig -> EkgMetrics.Store -> Moonshine -> IO ()
startServer ServerConfig { applicationConnector, adminConnector } metricsStore (M routes) = do
  mapM_ startMetricsServer adminConnector
  routesWithMetrics <- mapM (monitorRoute metricsStore) routes
  httpServe snapConfig (Snap.route routesWithMetrics)

  where
    monitorRoute :: EkgMetrics.Store -> (ByteString, Snap ()) -> IO (ByteString, Snap ())
    monitorRoute metricsStore (path, snap) = do -- IO monad
      timer <- getDistribution (decodeUtf8 path) metricsStore
      return (path, monitoredRoute timer snap)

    monitoredRoute :: Distribution -> Snap () -> Snap ()
    monitoredRoute timer snap = do -- snap monad
      start <- liftIO getCurrentTime
      result <- snap
      end <- liftIO getCurrentTime
      addTiming start end
      return result
      where
        addTiming start end = liftIO $
          D.add timer diff
          where
            diff = toDouble (diffUTCTime end start)
            toDouble = fromRational . toRational

    startMetricsServer :: ConnectorConfig -> IO Server
    startMetricsServer ConnectorConfig { scheme=HTTP, port } = forkServerWith metricsStore "0.0.0.0" port
    startMetricsServer ConnectorConfig { scheme=HTTPS } = error "EKG does not support running on HTTPS"

    snapConfig :: Config m a
    snapConfig = mconcat $ map toSnapConfig applicationConnector
    toSnapConfig :: ConnectorConfig -> Config m a
    toSnapConfig ConnectorConfig { scheme=HTTP, port } = setPort port mempty
    toSnapConfig ConnectorConfig { scheme=HTTPS, port, cert=mcert, key=mkey } = case (do -- Maybe monad
      cert <- mcert
      key <- mkey
      return $ setSSLCert cert $ setSSLKey key $ setSSLPort port $ mempty) of
         Nothing -> error "You must provide cert and key in order to use HTTPS."
         Just config -> config
