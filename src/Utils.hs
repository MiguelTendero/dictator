{-# LANGUAGE NoImplicitPrelude   #-}
{-# LANGUAGE OverloadedLists     #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Utils where

import           Prelude                        ( (!!) )
import           Relude                  hiding ( First
                                                , get
                                                )


import qualified Data.Text                     as T
import           System.Random

randomChoice :: [a] -> StdGen -> a
randomChoice xs rng = xs !! n where n = fst $ randomR (0, length xs - 1) rng

data MessageFragment
    = TextBlock Text
    | CodeBlock Text
    deriving (Eq, Show)

fragmentText :: MessageFragment -> Text
fragmentText (TextBlock t) = t
fragmentText (CodeBlock t) = t

-- | Split a message into segments of code blocks and non-code-blocks.
messageSplit :: Text -> [MessageFragment]
messageSplit = filter (not . T.null . fragmentText) . splitMode True
  where
    isTick = (== '`')

    splitMode mode msg = if not $ T.null msg
        then case T.head msg of
            '`' -> splitMode (not mode) . tail' $ msg
            _ ->
                ctor (T.takeWhile (not . isTick) msg)
                    : (splitMode mode . T.dropWhile (not . isTick) $ msg)
        else []
        where ctor = if mode then TextBlock else CodeBlock
    tail' msg = if T.null msg then T.empty else T.tail msg

-- | Filter a message into dictator's voice, excluding code blocks.
voiceFilter :: Text -> Text
voiceFilter = T.concat . map format . messageSplit
  where
    format (TextBlock t) = "__**" <> (T.strip . T.toUpper) t <> "**__"
    format (CodeBlock t) = "```" <> t <> "```"

-- | Tokenize a message into individual words.
tokenizeMessage :: Text -> [Text]
tokenizeMessage =
    words
        . T.filter (not . isPunc)
        . T.concat
        . map fragmentText
        . filter (not . isCode)
        . messageSplit
  where
    punc :: String
    punc = "!?{}&>\"()|<[@]_+*:^p=;\\#£-/~%,.'"
    isPunc p = p `elem` punc
    -- Probably something built in to do this kind of work
    isCode (CodeBlock _) = True
    isCode _             = False

-- | Randomly choose true/false conveniently given a probability in [0.0, 1.0]
odds :: Double -> StdGen -> Bool
odds chance = (chance >) . fst . random