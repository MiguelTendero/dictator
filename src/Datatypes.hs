{-# LANGUAGE DeriveGeneric          #-}
{-# LANGUAGE LambdaCase             #-}
{-# LANGUAGE NoImplicitPrelude      #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE TemplateHaskell        #-}

module Datatypes
    (
    -- teams
      Team(..)
    , TeamData
    , Points
    , otherTeam
    , teamForbidden
    , teamRole
    , teamWarning
    , teamPoints
    , getTeam
    , setTeam
    , modifyTeam

    -- users
    , Credit
    , UserData
    , userTeam
    , userCredits
    , userTrinkets
    , getUser
    , setUser
    , modifyUser

    -- trinkets
    , TrinketID
    , TrinketData
    , Rarity(..)
    , trinketName
    , trinketRarity
    , displayTrinket
    , getTrinket
    , setTrinket

    -- locations
    , LocationData(..)
    , locationTrinkets
    , getLocation
    , setLocation
    , modifyLocation
    ) where

import           Relude                  hiding ( First
                                                , get
                                                )

import           DiscordUtils                   ( DH )

import           Control.Lens            hiding ( set )
import qualified Data.ByteString               as BS
import           Data.Default
import           Database.Redis
import           Discord.Internal.Types.Prelude


-- TYPES (definitions and instances)
------------------------------------

data Team = First | Second deriving (Eq, Generic, Read, Show)

otherTeam :: Team -> Team
otherTeam First  = Second
otherTeam Second = First

type Points = Integer

data TeamData = TeamData
    { _teamForbidden :: [Text]
    , _teamRole      :: Maybe RoleId
    , _teamWarning   :: Maybe MessageId
    , _teamPoints    :: Points
    }
    deriving Generic

makeLenses ''TeamData

instance Default TeamData


data Rarity = Common | Rare | Epic deriving (Eq, Generic, Read, Show)
type TrinketID = Int

data TrinketData = TrinketData
    { _trinketName   :: Text
    , _trinketRarity :: Rarity
    }
    deriving (Eq, Generic, Read, Show)

makeLenses ''TrinketData

displayRarity :: Rarity -> Text
displayRarity Common = "common"
displayRarity Rare   = "rare"
displayRarity Epic   = "epic"

displayTrinket :: TrinketID -> TrinketData -> Text
displayTrinket id_ trinket =
    "#"
        <> show id_
        <> " "
        <> (trinket ^. trinketName)
        <> " ("
        <> displayRarity (trinket ^. trinketRarity)
        <> ")"


type Credit = Double

data UserData = UserData
    { _userTeam     :: Maybe Team
    , _userCredits  :: Credit
    , _userTrinkets :: [TrinketID]
    }
    deriving (Eq, Generic, Read, Show)

makeLenses ''UserData

instance Default UserData


newtype LocationData = LocationData
    { _locationTrinkets :: [TrinketID]
    } deriving Generic

makeLenses ''LocationData

instance Default LocationData


-- DATABASE
-----------

runRedis' :: Connection -> Redis (Either Reply a) -> IO a
runRedis' c f = runRedis c f >>= either (die . show) return

getWithType :: Connection -> ByteString -> Text -> Text -> IO (Maybe Text)
getWithType conn type_ key field =
    runRedis'
            conn
            ( get
            . BS.intercalate ":"
            $ [type_, encodeUtf8 key, encodeUtf8 field]
            )
        <&> fmap decodeUtf8

setWithType :: Connection -> ByteString -> Text -> Text -> Text -> IO ()
setWithType conn type_ key field value = void . runRedis' conn $ set
    (BS.intercalate ":" [type_, encodeUtf8 key, encodeUtf8 field])
    (encodeUtf8 value)

readWithType
    :: Read b => Text -> (a -> Text) -> Connection -> a -> Text -> MaybeT IO b
readWithType type_ f conn id_ key =
    liftIO (getWithType conn (encodeUtf8 type_) (f id_) key)
        >>= hoistMaybe
        >>= hoistMaybe
        .   readMaybe
        .   toString

-- this is gross, i know. sorry!
showWithType
    :: (Show b)
    => Text
    -> (a -> Text)
    -> Connection
    -> a
    -> Text
    -> Getting b c b
    -> c
    -> IO ()
showWithType type_ f conn id_ key getter data_ =
    setWithType conn (encodeUtf8 type_) (f id_) key (show $ data_ ^. getter)


readUserType :: Read a => Connection -> UserId -> Text -> MaybeT IO a
readUserType = readWithType "users" show

showUserType
    :: Show a => Connection -> UserId -> Text -> Getting a b a -> b -> IO ()
showUserType = showWithType "users" show

getUser :: Connection -> UserId -> DH (Maybe UserData)
getUser conn userId = liftIO . runMaybeT $ do
    team     <- readUserType conn userId "team"
    credits  <- readUserType conn userId "credits"
    trinkets <- readUserType conn userId "trinkets"

    return UserData { _userTeam     = team
                    , _userCredits  = credits
                    , _userTrinkets = trinkets
                    }

setUser :: Connection -> UserId -> UserData -> DH ()
setUser conn userId userData = liftIO $ do
    showUserType conn userId "team"     userTeam     userData
    showUserType conn userId "credits"  userCredits  userData
    showUserType conn userId "trinkets" userTrinkets userData

modifyUser :: Connection -> UserId -> (UserData -> UserData) -> DH UserData
modifyUser conn userId f = do
    userData <- getUser conn userId <&> f . fromMaybe def
    setUser conn userId userData
    return userData


toTeamKey :: Team -> Text
toTeamKey = \case
    First  -> "1"
    Second -> "2"

readTeamType :: Read a => Connection -> Team -> Text -> MaybeT IO a
readTeamType = readWithType "teams" toTeamKey

showTeamType
    :: Show a => Connection -> Team -> Text -> Getting a b a -> b -> IO ()
showTeamType = showWithType "teams" toTeamKey

getTeam :: Connection -> Team -> DH (Maybe TeamData)
getTeam conn team = liftIO . runMaybeT $ do
    points    <- readTeamType conn team "points"
    role      <- readTeamType conn team "role"
    forbidden <- readTeamType conn team "forbidden"
    warning   <- readTeamType conn team "warning"

    return TeamData { _teamPoints    = points
                    , _teamRole      = role
                    , _teamForbidden = forbidden
                    , _teamWarning   = warning
                    }

setTeam :: Connection -> Team -> TeamData -> DH ()
setTeam conn team teamData = liftIO $ do
    showTeamType conn team "points"    teamPoints    teamData
    showTeamType conn team "role"      teamRole      teamData
    showTeamType conn team "forbidden" teamForbidden teamData
    showTeamType conn team "warning"   teamWarning   teamData

modifyTeam :: Connection -> Team -> (TeamData -> TeamData) -> DH TeamData
modifyTeam conn team f = do
    teamData <- getTeam conn team <&> f . fromMaybe def
    setTeam conn team teamData
    return teamData


readTrinketType :: Read a => Connection -> TrinketID -> Text -> MaybeT IO a
readTrinketType = readWithType "trinkets" show

showTrinketType
    :: Show a => Connection -> TrinketID -> Text -> Getting a b a -> b -> IO ()
showTrinketType = showWithType "trinkets" show

getTrinket :: Connection -> TrinketID -> DH (Maybe TrinketData)
getTrinket conn id_ = liftIO . runMaybeT $ do
    name   <- readTrinketType conn id_ "name"
    rarity <- readTrinketType conn id_ "rarity"

    return TrinketData { _trinketName = name, _trinketRarity = rarity }

setTrinket :: Connection -> TrinketID -> TrinketData -> DH ()
setTrinket conn trinketId trinketData = liftIO $ do
    showTrinketType conn trinketId "name"   trinketName   trinketData
    showTrinketType conn trinketId "rarity" trinketRarity trinketData


readLocationType :: Read a => Connection -> Text -> Text -> MaybeT IO a
readLocationType = readWithType "location" id

showLocationType
    :: Show a => Connection -> Text -> Text -> Getting a b a -> b -> IO ()
showLocationType = showWithType "location" id

getLocation :: Connection -> Text -> DH (Maybe LocationData)
getLocation conn name =
    liftIO . runMaybeT $ readLocationType conn name "trinkets" <&> LocationData

setLocation :: Connection -> Text -> LocationData -> DH ()
setLocation conn name locationData =
    liftIO $ showLocationType conn name "trinkets" locationTrinkets locationData

modifyLocation
    :: Connection -> Text -> (LocationData -> LocationData) -> DH LocationData
modifyLocation conn name f = do
    locationData <- getLocation conn name <&> f . fromMaybe def
    setLocation conn name locationData
    return locationData
