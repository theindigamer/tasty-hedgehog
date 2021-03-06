-- | This package lets you test Hedgehog properties with tasty.
-- 
-- Typical usage would look like this:
--
-- @ 
-- testGroup "tasty-hedgehog tests" [ 
--    testProperty "reverse involutive" prop_reverse_involutive
--  , testProperty "sort idempotent"    prop_sort_idempotent
--  ]
-- @ 
-- 
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Test.Tasty.Hedgehog (
    testProperty
  -- * Options you can pass in via tasty
  , HedgehogReplay(..)
  , HedgehogShowReplay(..)
  , HedgehogVerbose(..)
  , HedgehogTestLimit(..)
  , HedgehogDiscardLimit(..)
  , HedgehogShrinkLimit(..)
  , HedgehogShrinkRetries(..)
  ) where

import Data.Typeable

import qualified Test.Tasty.Providers as T
import Test.Tasty.Options

import Hedgehog
import Hedgehog.Internal.Property
import Hedgehog.Internal.Runner as H
import Hedgehog.Internal.Report
import Hedgehog.Internal.Seed as Seed

data HP = HP T.TestName Property
  deriving (Typeable)

-- | Create a 'Test' from a Hedgehog property
testProperty :: T.TestName -> Property -> T.TestTree
testProperty name prop = T.singleTest name (HP name prop)

-- | The replay token to use for replaying a previous test run
newtype HedgehogReplay = HedgehogReplay (Maybe (Size, Seed))
  deriving (Typeable)

instance IsOption HedgehogReplay where
  defaultValue = HedgehogReplay Nothing
  parseValue v = HedgehogReplay . Just <$> replay
    -- Reads a replay token in the form "{size} {seed}"
    where replay = (,) <$> safeRead (unwords size) <*> safeRead (unwords seed)
          (size, seed) = splitAt 2 $ words v
  optionName = return "hedgehog-replay"
  optionHelp = return "Replay token to use for replaying a previous test run"

-- | If a test case fails, show a replay token for replaying tests
newtype HedgehogShowReplay = HedgehogShowReplay Bool
  deriving (Typeable)

instance IsOption HedgehogShowReplay where
  defaultValue = HedgehogShowReplay True
  parseValue = fmap HedgehogShowReplay . safeRead
  optionName = return "hedgehog-show-replay"
  optionHelp = return "Show a replay token for replaying tests"

-- | Show the generated Hedgehog test cases
newtype HedgehogVerbose = HedgehogVerbose Bool
  deriving (Typeable)

instance IsOption HedgehogVerbose where
  defaultValue = HedgehogVerbose False
  parseValue = fmap HedgehogVerbose . safeRead
  optionName = return "hedgehog-verbose"
  optionHelp = return "Show the generated Hedgehog test cases"
  optionCLParser = flagCLParser Nothing (HedgehogVerbose True)

-- | The number of successful test cases required before Hedgehog will pass a test
newtype HedgehogTestLimit = HedgehogTestLimit Int
  deriving (Eq, Ord, Show, Num, Enum, Real, Integral, Typeable)

instance IsOption HedgehogTestLimit where
  defaultValue = 100
  parseValue = fmap HedgehogTestLimit . safeRead
  optionName = return "hedgehog-tests"
  optionHelp = return "Number of successful test cases required before Hedgehog will pass a test"

-- | The number of discarded cases allowed before Hedgehog will fail a test
newtype HedgehogDiscardLimit = HedgehogDiscardLimit Int
  deriving (Eq, Ord, Show, Num, Enum, Real, Integral, Typeable)

instance IsOption HedgehogDiscardLimit where
  defaultValue = 100
  parseValue = fmap HedgehogDiscardLimit . safeRead
  optionName = return "hedgehog-discards"
  optionHelp = return "Number of discarded cases allowed before Hedgehog will fail a test"

-- | The number of shrinks allowed before Hedgehog will fail a test
newtype HedgehogShrinkLimit = HedgehogShrinkLimit Int
  deriving (Eq, Ord, Show, Num, Enum, Real, Integral, Typeable)

instance IsOption HedgehogShrinkLimit where
  defaultValue = 100
  parseValue = fmap HedgehogShrinkLimit . safeRead
  optionName = return "hedgehog-shrinks"
  optionHelp = return "Number of shrinks allowed before Hedgehog will fail a test"
  
-- | The number of times to re-run a test during shrinking
newtype HedgehogShrinkRetries = HedgehogShrinkRetries Int
  deriving (Eq, Ord, Show, Num, Enum, Real, Integral, Typeable)

instance IsOption HedgehogShrinkRetries where
  defaultValue = 10
  parseValue = fmap HedgehogShrinkRetries . safeRead
  optionName = return "hedgehog-retries"
  optionHelp = return "Number of times to re-run a test during shrinking"
        
reportToProgress :: Int
                 -> Int
                 -> Int
                 -> Report Progress
                 -> T.Progress
reportToProgress testLimit _ shrinkLimit (Report testsDone _ status) =
  let
    ratio x y = 1.0 * fromIntegral x / fromIntegral y
  in
    -- TODO add details for tests run / discarded / shrunk
    case status of
      Running ->
        T.Progress "Running" (ratio testsDone testLimit)
      Shrinking fr ->
        T.Progress "Shrinking" (ratio (failureShrinks fr) shrinkLimit)

reportOutput :: Bool
             -> Bool
             -> String
             -> Report Result
             -> IO String
reportOutput _ showReplay name report@(Report _ _ status) = do
  -- TODO add details for tests run / discarded / shrunk
  s <- renderResult Nothing (Just (PropertyName name)) report
  pure $ case status of
    Failed fr -> do
      let
        size = failureSize fr
        seed = failureSeed fr
        replayStr =
          if showReplay
          then "\nUse '--hedgehog-replay \"" ++ show size ++ " " ++ show seed ++ "\"' to reproduce."
          else ""
      s ++ replayStr
    GaveUp -> "Gave up"
    OK -> "OK"

instance T.IsTest HP where
  testOptions =
    return [ Option (Proxy :: Proxy HedgehogReplay)
           , Option (Proxy :: Proxy HedgehogShowReplay)
           , Option (Proxy :: Proxy HedgehogVerbose)
           , Option (Proxy :: Proxy HedgehogTestLimit)
           , Option (Proxy :: Proxy HedgehogDiscardLimit)
           , Option (Proxy :: Proxy HedgehogShrinkLimit)
           , Option (Proxy :: Proxy HedgehogShrinkRetries)
           ]

  run opts (HP name (Property _ pTest)) yieldProgress = do
    let
      HedgehogReplay         replay = lookupOption opts
      HedgehogShowReplay showReplay = lookupOption opts
      HedgehogVerbose       verbose = lookupOption opts
      HedgehogTestLimit       tests = lookupOption opts
      HedgehogDiscardLimit discards = lookupOption opts
      HedgehogShrinkLimit   shrinks = lookupOption opts
      HedgehogShrinkRetries retries = lookupOption opts
      config =
        PropertyConfig
          (TestLimit tests)
          (DiscardLimit discards)
          (ShrinkLimit shrinks)
          (ShrinkRetries retries)

    randSeed <- Seed.random
    let
      size = maybe 0 fst replay
      seed = maybe randSeed snd replay

    report <- checkReport config size seed pTest (yieldProgress . reportToProgress tests discards shrinks)

    let
      resultFn = if reportStatus report == OK
                 then T.testPassed
                 else T.testFailed

    out <- reportOutput verbose showReplay name report
    return $ resultFn out
