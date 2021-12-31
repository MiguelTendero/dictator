-- | Specifies the game involving trinkets, locations and credits.

{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE MultiWayIf #-}

module Game
    (
    -- trinkets
      getNewTrinket
    , mkNewTrinket
    , combineTrinkets
    , fightTrinkets
    , FightData(..)
    , getTrinketAction
    , getRandomTrinket
    , randomNewTrinketRarity
    , randomExistingTrinketRarity
    , rareTrinketExamples
    , legendaryTrinketExamples
    , printTrinkets
    , trinketColour
    , nextTrinketId

    -- conversion
    , itemsToUser
    , userToItems
    , fromTrinkets
    , fromCredits

    -- economy
    , userOwns
    , giveItems
    , takeItems
    , takeOrComplain
    , ownsOrComplain
    , takeOrPunish
    , punishWallet
    , fightEmbed
    ) where

import           Relude                  hiding ( First
                                                , get
                                                )

import           Game.Data
import           Game.Items
import           Utils.Discord
import           Utils.Language                 ( J1Opts(J1Opts)
                                                , getJ1
                                                , getJ1With
                                                , makePrompt
                                                )

import           Data.MultiSet                  ( MultiSet )

import           Control.Lens            hiding ( noneOf )
import           Control.Monad.Except           ( MonadError(throwError) )
import           Data.Default                   ( def )
import           Data.List                      ( maximum )
import qualified Data.MultiSet                 as MS
import qualified Data.Text                     as T
import qualified Database.Redis                as DB
import           Discord.Internal.Types.Prelude
import           Discord.Types                  ( CreateEmbed )
import           System.Random
import           Text.Parsec             hiding ( (<|>) )


-- trinkets (high-level)
------------------------

getRandomTrinket :: DB.Connection -> Rarity -> DictM (TrinketID, TrinketData)
getRandomTrinket conn rarity = do
    maxTrinketID <- nextTrinketId conn <&> pred
    trinketID    <- randomRIO (1, maxTrinketID)
    getTrinket conn trinketID >>= \case
        Just trinket | (trinket ^. trinketRarity) == rarity ->
            return (trinketID, trinket)
        _ -> getRandomTrinket conn rarity

-- | Not only retrieves a new trinket, but adds it to the database.
mkNewTrinket :: DB.Connection -> Rarity -> DictM (TrinketID, TrinketData)
mkNewTrinket conn rarity = do
    tId     <- nextTrinketId conn
    trinket <- getNewTrinket conn rarity
    setTrinket conn tId trinket
    return (tId, trinket)

-- | Does not add trinkets to the database. You might want to use mkNewTrinket instead!
getNewTrinket :: DB.Connection -> Rarity -> DictM TrinketData
getNewTrinket conn rarity = do
    res <- getJ1 20 prompt
    case listToMaybe . rights . fmap parseTrinketName . lines $ res of
        Just name -> do
            valid <- validTrinketName name
            if valid
                then return $ TrinketData name rarity
                else getNewTrinket conn rarity
        Nothing -> getNewTrinket conn rarity
  where
    promptTrinkets = makePrompt . map (<> ".") $ case rarity of
        Common    -> commonTrinketExamples
        Uncommon  -> uncommonTrinketExamples
        Rare      -> rareTrinketExamples
        Legendary -> legendaryTrinketExamples
    prompt =
        "There exists a dictator of an online chatroom who is eccentric but evil. He often gives out items. Here are some examples of "
            <> show rarity
            <> " items.\n"
            <> promptTrinkets

combineTrinkets
    :: DB.Connection
    -> TrinketData
    -> TrinketData
    -> DictM (TrinketID, TrinketData)
combineTrinkets conn t1 t2 = do
    res <- getJ1With (J1Opts 0.9 0.9) 16 prompt
    let rarity = maximum . fmap (view trinketRarity) $ [t1, t2]
    let mayTrinket =
            rightToMaybe . parseTrinketCombination <=< listToMaybe . lines $ res
    case mayTrinket of
        Nothing   -> combineTrinkets conn t1 t2
        Just name -> do
            valid <- validTrinketName name
            let absorbed = name `elem` fmap (view trinketName) [t1, t2]

            if valid && not absorbed
                then do
                    let trinket = TrinketData name rarity
                    tId <- nextTrinketId conn
                    setTrinket conn tId trinket
                    return (tId, trinket)
                else combineTrinkets conn t1 t2
  where
    examples =
        [ "In an online message board, items can be combined together to create new items. Here are some examples of various combinations."
        , "Item 1: a tin can. Item 2: 3.2g of gunpowder. Result: a bomb."
        , "Item 1: a small bird. Item 2: a small bird. Result: a large bird."
        , "Item 1: a permit to ban one user of your choice. Item 2: another user. Result: BANNED."
        , "Item 1: a remote tropical island with coconuts and a treasure chest and rum. Item 2: a rusty key. Result: rum"
        , "Item 1: the ability to control time. Item 2: a portal to another dimension. Result: Godhood."
        , "Item 1: a bag of dicks. Item 2: your ass. Result: dicks up your ass."
        , "Item 1: just a sandy sea. Item 2: a spare rubber x. Result: gibberish."
        , "Item 1: an ache of discontent. Item 2: a polaroid peel-off. Result: a depressing photograph."
        , "Item 1: a tiny cookie. Item 2: blood dreams of a dead end Result: a cookie with blood."
        , "Item 1: a baby with no arms or legs. Item 2: arms and legs. Result: a baby."
        , "Item 1: a poor girl. Item 2: a heart. Result: a happy girl."
        ]
    prompt =
        unlines examples
            <> "\nItem 1: "
            <> t1
            ^. trinketName
            <> ". Item 2: "
            <> t2
            ^. trinketName
            <> ". Result: "

-- Some data representing a fight.
data FightData = FightData
    { fightWinnerIsFirst :: Bool
    , fightDescription   :: Text
    }

fightEmbed
    :: (TrinketID, TrinketData)
    -> (TrinketID, TrinketData)
    -> FightData
    -> DictM CreateEmbed
fightEmbed (t1, attacker) (t2, defender) fightData = do
    attackerDesc <- displayTrinket t1 attacker
    defenderDesc <- displayTrinket t2 defender
    let FightData attackerWins fightDesc = fightData
        winDesc = if attackerWins then "wins" else "loses"
        winnerColour = if attackerWins
            then trinketColour (attacker ^. trinketRarity)
            else trinketColour (defender ^. trinketRarity)
        embedDesc =
            attackerDesc
                <> " fights "
                <> defenderDesc
                <> " and "
                <> winDesc
                <> "! "
                <> fightDesc
                <> "."
    return $ mkEmbed "Trinket fight!" embedDesc [] (Just winnerColour)

fightTrinkets :: TrinketData -> TrinketData -> Maybe Bool -> DictM FightData
fightTrinkets t1 t2 winner = do
    res <- getJ1With (J1Opts 0.9 0.9) 16 (prompt t1 t2)
    let mayResult =
            rightToMaybe
                .   traceShow res
                .   traceShowId
                .   parse parTrinketCombat ""
                <=< listToMaybe
                .   lines
                $   "Winner: "
                <>  winnerText t1 t2
                <>  res
    case mayResult of
        Nothing                  -> fightTrinkets t1 t2 winner
        Just (firstWon, details) -> return $ FightData firstWon details
  where
    examples =
        [ "Item 1: a baby with no limbs. Item 2: a type of vehicle. Winner: vehicle. Desc: A lot of crying from a flattened baby."
        , "Item 1: a makeshift bomb. Item 2: everything. Winner: bomb. Desc: Anything and everything can be blown up."
        , "Item 1: a free pass to ban one member. Item 2: a warehouse. Winner: ban. Desc: The warehouse gets banned."
        , "Item 1: a crocodile with no jaws. Item 2: the ability to travel through time. Winner: time travel. Desc: A crocodile dies of old age."
        , "Item 1: large turnips. Item 2: a poisonous snake. Winner: snake. Desc: The turnips get poisoned."
        , "Item 1: KILL. Item 2: a bed. Winner: KILL. Desc: Bed KILLED."
        , "Item 1: complete and utter silence. Item 2: tasty steak. Winner: steak. Desc: It's no longer silent."
        , "Item 1: a small cookie. Item 2: a clean shirt. Winner: cookie. Desc: Cookie crumbs all over the damn shirt."
        , "Item 1: a sheet of paper. Item 2: a knife. Winner: knife. Desc: The knife slices through the sheet of paper."
        ]
    prompt t1' t2' =
        "In an online message board, items can be put to fight against each other. The more violent items often win. Here are some examples"
            <> T.unlines examples
            <> "\nItem 1: "
            <> (t1' ^. trinketName)
            <> " Item 2: "
            <> (t2' ^. trinketName)
            <> " Winner:"
            <> winnerText t1' t2'
    -- The rarest trinket wins; we leave it blank if they're equal and let the language model decide.
    winnerText t1 t2 = case winner of
        Just True  -> " " <> t1 ^. trinketName
        Just False -> " " <> t2 ^. trinketName
        Nothing    -> ""
    parTrinketCombat = do
        -- void $ string "Winner: "
        -- firstWins <- anyChar >>= \case
        --     '1' -> return True
        --     '2' -> return False
        --     _   -> fail "Winner has to be one of '1' or '2'"
        -- FIXME
        winnerWords <-
            some (noneOf ".")
            <&> traceShowId
            .   MS.fromList
            .   filter ((> 2) . T.length)
            .   words
            .   fromString
        let t1Words =
                traceShowId
                    $ MS.fromList
                    . filter ((> 3) . T.length)
                    . words
                    . view trinketName
                    $ t1
            t2Words =
                traceShowId
                    $ MS.fromList
                    . filter ((> 3) . T.length)
                    . words
                    . view trinketName
                    $ t1
        -- firstWins <-
        --     (string (toString $ t1 ^. trinketName) >> return True)
        --         <|> (string (toString $ t2 ^. trinketName) >> return False)
        void $ string ". Desc: "
        desc      <- manyTill anyChar (char '.')
        firstWins <-
            if
                | not . MS.null . MS.intersection t1Words $ winnerWords
                -> pure True
                | not . MS.null . MS.intersection t2Words $ winnerWords
                -> pure False
                | otherwise
                -> fail "incomprehensible result"
        return (firstWins, fromString desc)

getTrinketAction :: TrinketData -> DictM Text
getTrinketAction t = do
    getJ1 16 prompt >>= either (const $ getTrinketAction t) return . parse
        (some (noneOf ".") <&> fromString)
        ""
  where
    examples =
        [ "Item: a bomb. Action: explodes."
        , "Item: a human cell. Action: self-replicates."
        , "Item: a gateway to another world. Action: takes someone to another world."
        , "Item: a large egg. Action: becomes rotten."
        , "Item: ebola. Action: makes someone sick."
        ]
    prompt = makePrompt examples <> "Item: " <> t ^. trinketName <> ". Action:"


-- trinkets (low-level)
-----------------------

randomNewTrinketRarity :: DictM Rarity
randomNewTrinketRarity = do
    outcome :: Double <- randomIO
    return $ if
        | 0.00 < outcome && outcome <= 0.70 -> Common
        | 0.70 < outcome && outcome <= 0.90 -> Uncommon
        | 0.90 < outcome && outcome <= 0.97 -> Rare
        | 0.97 < outcome && outcome <= 1.00 -> Legendary
        | otherwise                         -> Common

randomExistingTrinketRarity :: DictM Rarity
randomExistingTrinketRarity = do
    outcome :: Double <- randomIO
    return $ if
        | 0.00 < outcome && outcome <= 0.90 -> Common
        | 0.90 < outcome && outcome <= 0.97 -> Uncommon
        | 0.97 < outcome && outcome <= 1.00 -> Rare
        | otherwise                         -> Common

-- | Canonical trinket colors for embeds.
-- | In order: White, blue, purple, gold.
trinketColour :: Rarity -> ColorInteger
trinketColour Common    = 0xB3C0B7
trinketColour Uncommon  = 0x0F468A
trinketColour Rare      = 0x6B007F
trinketColour Legendary = 0xFBB90C

commonTrinketExamples :: [Text]
commonTrinketExamples =
    [ "3.67oz of rust"
    , "a small bird"
    , "a new mobile phone"
    , "a jar of jam"
    , "three messages"
    , "a ball of purple yawn"
    , "silly little thing"
    , "a lump of lead"
    , "an oily tin can"
    ]

uncommonTrinketExamples :: [Text]
uncommonTrinketExamples =
    [ "a ball of pure malignant evil"
    , "the awfulness of your post"
    , "three message board roles"
    , "nothing"
    , "a glue covered, soaking wet pillow"
    , "a gateway into another world"
    , "a bloody machete"
    , "two smelly socks"
    , "an empty warehouse"
    ]

rareTrinketExamples :: [Text]
rareTrinketExamples =
    [ "a free pass to ban one member"
    , "something really good or at least above average"
    , "the ability to control time"
    , "whatever you want, babe"
    , "the beauty that the world is full to the brim with"
    , "the scummiest and rarest"
    , "at least five other trinkets"
    , "temporary immortality"
    ]

legendaryTrinketExamples :: [Text]
legendaryTrinketExamples =
    [ "a free pass to ban one member"
    , "a bag of dicks"
    , "rough homosexual intercourse"
    , "the entirety of postrat Twitter"
    , "the holy excrement of God Himself"
    , "ownership of the entire forum"
    , "anti-semitism, racism, just general bigotry"
    , "every trinket that exists or will exist"
    , "a hugely oversized penis"
    , "sword of the shitposter (special item)"
    , "control of the official ideology of the message board"
    ]

validTrinketName :: Text -> DictM Bool
validTrinketName t = do
    -- TODO check if name refers to existing trinket
    return
        $         not ("A " `T.isPrefixOf` t')
        &&        t'
        `notElem` (  commonTrinketExamples
                  <> uncommonTrinketExamples
                  <> rareTrinketExamples
                  <> legendaryTrinketExamples
                  )
    where t' = T.strip t

parseTrinketName :: Text -> Either ParseError Text
parseTrinketName =
    parse (fmap fromString $ string "- " *> manyTill anyChar (string ".")) ""

parseTrinketCombination :: Text -> Either ParseError Text
parseTrinketCombination =
    parse (fromString <$> manyTill anyChar (string ".")) ""

nextTrinketId :: DB.Connection -> DictM Int
nextTrinketId conn = go 1  where
    go n = do
        trinket <- getTrinket conn n
        case trinket of
            Just _  -> go (n + 1)
            Nothing -> return n

printTrinkets :: DB.Connection -> MultiSet TrinketID -> DictM [Text]
printTrinkets conn trinkets = do
    pairs <-
        forM
                (MS.elems trinkets)
                (\t -> do
                    trinketData <- getTrinket conn t
                    return (t, trinketData)
                )
            <&> MS.fromList
    displays <- mapM
        (\case
            (trinket, Just trinketData) ->
                displayTrinket trinket trinketData <&> Just
            (_, Nothing) -> return Nothing
        )
        (MS.elems pairs)
    (return . catMaybes) displays


-- items
--------

fromTrinkets :: MultiSet TrinketID -> Items
fromTrinkets trinkets = def & itemTrinkets .~ trinkets

fromCredits :: Credit -> Items
fromCredits credits = def & itemCredits .~ credits

-- | Project a user into a collection of only their item data.
userToItems :: UserData -> Items
userToItems userData = Items { _itemCredits  = userData ^. userCredits
                             , _itemTrinkets = userData ^. userTrinkets
                             }

-- | Given a user, update their item data to the following.
itemsToUser :: UserData -> Items -> UserData
itemsToUser userData items =
    userData
        &  userCredits
        .~ (items ^. itemCredits)
        &  userTrinkets
        .~ (items ^. itemTrinkets)

-- | Take a set of items from a user without any checking.
takeItems :: DB.Connection -> UserId -> Items -> DictM ()
takeItems conn user items = void $ modifyUser conn user removeItems
  where
    removeItems userData =
        userData
            &  userCredits
            -~ (items ^. itemCredits)
            &  userTrinkets
            %~ (MS.\\ (items ^. itemTrinkets))

combineItems :: Items -> Items -> Items
combineItems it1 it2 = Items
    { _itemCredits  = it1 ^. itemCredits + it2 ^. itemCredits
    , _itemTrinkets = (it1 ^. itemTrinkets) `MS.union` (it2 ^. itemTrinkets)
    }


-- generic
----------

userOwns :: UserData -> Items -> Bool
userOwns userData items =
    let
        Items { _itemCredits = claimedCredits, _itemTrinkets = claimedTrinkets }
            = items
        ownsCredits =
            claimedCredits <= 0 || (userData ^. userCredits) >= claimedCredits
        ownsTrinkets =
            claimedTrinkets `MS.isSubsetOf` (userData ^. userTrinkets)
    in
        ownsCredits && ownsTrinkets

-- Subtract the set canonical amount from a wallet.
decrementWallet :: DB.Connection -> UserId -> DictM ()
decrementWallet conn user = void $ modifyUser conn user (over userCredits pred)

-- | Punish a wallet with a message. You probably want to use takeOrPunish or takeOrComplain instead.
punishWallet :: DB.Connection -> UserId -> DictM ()
punishWallet conn user = do
    sendMessageToGeneral
        "You don't have the goods you so shamelessly claim ownership to, and now you own even less. Credits, that is."
    decrementWallet conn user

-- | Add items to a users inventory.
giveItems :: DB.Connection -> UserId -> Items -> DictM ()
giveItems conn user gift = do
    userData <- getUser conn user <&> fromMaybe def
    let newItems = combineItems gift . userToItems $ userData
    setUser conn user . itemsToUser userData $ newItems

-- | Take a set of items, returning False when they weren't owned.
takeOrPunish :: DB.Connection -> UserId -> Items -> DictM Bool
takeOrPunish conn user items = do
    userData <- getUser conn user <&> fromMaybe def
    let res = userOwns userData items
    if res then takeItems conn user items else punishWallet conn user
    return res

-- | Take a set of items, throwing a complaint when they weren't owned.
takeOrComplain :: DB.Connection -> UserId -> Items -> DictM ()
takeOrComplain conn user items = do
    ownsOrComplain conn user items
    takeItems conn user items

-- | Check ownership of a set of items, throwing a complaint when they weren't owned.
ownsOrComplain :: DB.Connection -> UserId -> Items -> DictM ()
ownsOrComplain conn user items = do
    owned <- getUser conn user <&> flip userOwns items . fromMaybe def
    unless owned $ do
        decrementWallet conn user
        throwError
            $ Complaint
                  "You don't have the goods you so shamelessly claim ownership to, and now you have even less. Credits, that is."
